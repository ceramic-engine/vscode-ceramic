package;

import haxe.Timer;
import js.html.Console;
import sys.io.File;
import haxe.io.Path;
import haxe.Json;
import js.node.ChildProcess;

import vscode.ExtensionContext;
import vscode.StatusBarItem;
import vscode.FileSystemWatcher;

using StringTools;

typedef IdeInfoTargetItem = {

    var name:String;

    var command:String;

    @:optional var args:Array<String>;

    /** The groups this task belongs to. */
    @:optional var groups:Array<String>;

    @:optional var select:IdeInfoTargetSelectItem;

}

typedef IdeInfoTargetSelectItem = {

    var command:String;

    @:optional var args:Array<String>;

}

typedef IdeInfoVariantItem = {

    var name:String;

    @:optional var args:Array<String>;

    /** On which task group this variant can be used. */
    @:optional var group:String;

    /** We can only choose one variant for each role at a time. */
    @:optional var role:String;

    @:optional var select:IdeInfoVariantSelectItem;

}

typedef IdeInfoVariantSelectItem = {

    @:optional var args:Array<String>;

}

typedef UserInfo = {

    var ceramicProject:String;

    var perProjectSettings:Dynamic<ProjectUserInfo>;

}

typedef ProjectUserInfo = {

    var target:String;

    var perTargetVariant:Dynamic<String>;

}

class VscodeCeramic {

/// Exposed

    static var instance:VscodeCeramic = null;

    @:expose("activate")
    static function activate(context:ExtensionContext) {

        instance = new VscodeCeramic(context);

    }

/// Properties

    var context:ExtensionContext;

    var watchingWorkspace:Bool = false;

    var watcher:FileSystemWatcher;

    var ceramicProjectStatusBarItem:StatusBarItem;

    var targetStatusBarItem:StatusBarItem;

    var variantStatusBarItem:StatusBarItem;

    var numStatusBars:Int = 0;

    var availableCeramicProjects:Array<String> = [];

    var selectedCeramicProject(get, set):String;

    var availableTargets:Array<String> = [];

    var selectedTarget:String = null;

    var userInfo:UserInfo;

    var userInfoDirty(default, set):Bool = false;

    var ideTargets:Array<IdeInfoTargetItem> = null;

    var ideVariants:Array<IdeInfoTargetSelectItem> = null;

/// Lifecycle

    function new(context:ExtensionContext) {

        this.context = context;
        
        loadUserInfo();

        context.subscriptions.push(Vscode.commands.registerCommand("ceramic.load", function() {
            loadCeramicContext();
        }));

        context.subscriptions.push(Vscode.commands.registerCommand("ceramic.select-ceramic-project", function() {
            selectCeramicProject();
        }));

        context.subscriptions.push(Vscode.commands.registerCommand("ceramic.select-target", function() {
            selectTarget();
        }));

        context.subscriptions.push(Vscode.commands.registerCommand("ceramic.select-variant", function() {
            selectVariant();
        }));

        loadCeramicContext();

    }

/// User info

    function loadUserInfo() {

        var rawUserInfo = context.workspaceState.get('ceramicUserInfo');
        try {
            userInfo = Json.parse(rawUserInfo);
        }
        catch (e:Dynamic) {
            // Failed to parse data?
        }
        if (userInfo == null) {
            userInfo = {
                ceramicProject: null,
                perProjectSettings: {}
            };
        }

    }

    function saveUserInfo() {

        context.workspaceState.update('ceramicUserInfo', Json.stringify(userInfo));

    }

    function set_userInfoDirty(userInfoDirty:Bool):Bool {

        if (this.userInfoDirty == userInfoDirty)
            return userInfoDirty;
        
        this.userInfoDirty = userInfoDirty;
        if (userInfoDirty) {
            Timer.delay(saveUserInfo, 250);
        }

        return userInfoDirty;

    }

    function get_selectedCeramicProject():String {

        return userInfo.ceramicProject;

    }

    function set_selectedCeramicProject(selectedCeramicProject:String):String {

        var result = userInfo.ceramicProject = selectedCeramicProject;
        userInfoDirty = true;
        return result;

    }

/// Watch

    function watchCeramicProjectFiles():Void {

        if (!checkWorkspaceFolder()) {
            return;
        }

        var filePattern = '**/ceramic.yml';

        trace('FIND FILES (pattern: $filePattern)');

        Vscode.workspace.findFiles(filePattern).then(function(result) {

            for (uri in result) {
                trace('DETECT $uri');
                createOrUpdateCeramicPath(uri.path);
            }

            watcher = Vscode.workspace.createFileSystemWatcher(filePattern, false, false, false);
    
            context.subscriptions.push(watcher.onDidChange(function(uri) {
                trace('CHANGE $uri');
                createOrUpdateCeramicPath(uri.path);
            }));
            context.subscriptions.push(watcher.onDidCreate(function(uri) {
                trace('CREATE $uri');
                createOrUpdateCeramicPath(uri.path);
            }));
            context.subscriptions.push(watcher.onDidDelete(function(uri) {
                trace('DELETE $uri');
                removeCeramicPath(uri.path);
            }));
            context.subscriptions.push(watcher);
        });

        watchingWorkspace = true;

    }

    function createOrUpdateCeramicPath(path:String) {

        if (availableCeramicProjects.indexOf(path) == -1) {
            availableCeramicProjects.push(path);
            sortAlphabetically(availableCeramicProjects);
            updateFromSelectedCeramicProject();
        }
        
    }

    function removeCeramicPath(path:String) {

        var shouldRefresh = false;
        var index = availableCeramicProjects.indexOf(path);

        if (index != -1) {
            availableCeramicProjects.splice(index, 1);
            sortAlphabetically(availableCeramicProjects);
            shouldRefresh = true;
        }

        if (path == selectedCeramicProject) {
            selectedCeramicProject = null;
            shouldRefresh = true;
        }

        if (shouldRefresh)
            updateFromSelectedCeramicProject();
        
    }

    function updateFromSelectedCeramicProject() {
        
        if (selectedCeramicProject == null && availableCeramicProjects.length > 0) {
            selectedCeramicProject = availableCeramicProjects[0];
        }

        var title = selectedCeramicProject != null ? computeShortPath(selectedCeramicProject) : '⚠️ no ceramic project';
        var description = selectedCeramicProject != null ? selectedCeramicProject : 'This workspace doesn\'t have any ceramic.yml file';

        ceramicProjectStatusBarItem = updateStatusBarItem(
            ceramicProjectStatusBarItem,
            title,
            description,
            'ceramic.select-ceramic-project'
        );

        if (selectedCeramicProject != null) {
            fetchTargets();
        }

    }

    var fetchingTargets:Bool = false;
    var shouldFetchAgain:Bool = false;
    function fetchTargets() {

        trace('FETCH TARGETS $selectedCeramicProject');

        if (fetchingTargets) {
            trace('- already fetching -');
            shouldFetchAgain = true;
            return;
        }
        fetchingTargets = true;

        command('ceramic', ['ide', 'info', '--print-split-lines'], { cwd: Path.directory(selectedCeramicProject), showError: true }, function(code, out, err) {
            fetchingTargets = false;

            trace('-> fetch result');

            if (shouldFetchAgain) {
                trace('   FETCH AGAIN');
                shouldFetchAgain = false;
                fetchTargets();
                return;
            }

            var data = Json.parse(out);
            ideTargets = data.ide.targets;
            ideVariants = data.ide.variants;
            
            availableTargets = []; 
            for (ideTarget in ideTargets) {
                availableTargets.push(ideTarget.name);
            }

            updateFromSelectedTarget();
        });

    }

    function updateFromSelectedTarget() {

        if (selectedTarget != null && availableTargets.indexOf(selectedTarget) == -1) {
            selectedTarget = null;
        }
        
        if (selectedTarget == null && availableTargets.length > 0) {
            selectedTarget = availableTargets[0];
        }

        var title = selectedTarget != null ? selectedTarget : '⚠️ no target';
        var description = selectedTarget != null ? selectedTarget : 'No target available for this ceramic project';

        trace('update from selected target title=$title available=$availableTargets');

        targetStatusBarItem = updateStatusBarItem(
            targetStatusBarItem,
            title,
            description,
            'ceramic.select-target'
        );

        if (selectedTarget != null) {
            // TODO compute variants
        }

    }

    function sortAlphabetically(array:Array<String>) {

        array.sort(function(a, b) {
            a = a.toUpperCase();
            b = b.toUpperCase();

            if (a < b) {
                return -1;
            }
            else if (a > b) {
                return 1;
            }
            else {
                return 0;
            }
        });

    }

/// Actions

    function loadCeramicContext() {

        trace('LOAD CERAMIC CONTEXT');

        if (!watchingWorkspace)
            watchCeramicProjectFiles();

    }

    function reload():Void {

        if (!checkWorkspaceFolder()) {
            Vscode.window.showErrorMessage("Failed to load: **ceramic.yml** because there is no folder opened.");
            return;
        }

        try {

            trace('TRY CERAMIC CMD');
            command('ceramic', ['ide', 'info'], { cwd: getRootPath(), showError: true }, function(code, out, err) {

                trace('OUT: $out');

            });

            // TODO
            /*
            var listPath = Path.join([getRootPath(), '.vscode/tasks-chooser.json']);
            listContent = Json.parse(File.getContent(listPath));

            tasksPath = Path.join([getRootPath(), '.vscode/tasks.json']);
            var tasksContent:Dynamic = null;
            try {
                tasksContent = Json.parse(File.getContent(tasksPath));
            } catch (e1:Dynamic) {}

            var targetIndex = 0;
            if (tasksContent != null && tasksContent.chooserIndex != null) {
                targetIndex = tasksContent.chooserIndex;
            }
            targetIndex = cast Math.min(targetIndex, listContent.items.length - 1);

            setChooserIndex(targetIndex);
            */
        }
        catch (e:Dynamic) {
            Vscode.window.showErrorMessage("Failed to load: **ceramic.yml**. Please check its content is valid.");
            js.Node.console.error(e);
        }

    }

    function selectCeramicProject() {

        var pickItems:Array<Dynamic> = [];
        var index = 0;
        var availableCeramicProjects = [].concat(this.availableCeramicProjects);
        var shortPaths = computeShortPaths(availableCeramicProjects);
        for (path in availableCeramicProjects) {
            pickItems.push({
                label: shortPaths[index],
                description: path,
                index: index,
            });
            index++;
        }

        // Put selected project at the top
        var selectedIndex = availableCeramicProjects.indexOf(selectedCeramicProject);
        if (selectedIndex != -1) {
            var selectedItem = pickItems[selectedIndex];
            pickItems.splice(selectedIndex, 1);
            pickItems.unshift(selectedItem);
        }

        var placeHolder = 'Select ceramic project';

        Vscode.window.showQuickPick(pickItems, { placeHolder: placeHolder }).then(function(choice:Dynamic) {
            if (choice == null || choice.index == selectedIndex) {
                return;
            }
            
            try {
                selectedCeramicProject = availableCeramicProjects[choice.index];
                updateFromSelectedCeramicProject();
            }
            catch (e:Dynamic) {
                Vscode.window.showErrorMessage("Failed to select ceramic project: " + e);
                js.Node.console.error(e);
            }

        });

    }

    function computeShortPath(path:String):String {

        var rootPath = getRootPath();

        if (rootPath != null && path.startsWith(rootPath)) {
            return path.substring(rootPath.length + 1);
        }
        else {
            return path;
        }

    }

    function computeShortPaths(paths:Array<String>):Array<String> {

        var rootPath = getRootPath();

        var result = [];

        for (path in paths) {
            if (rootPath != null && path.startsWith(rootPath)) {
                result.push(path.substring(rootPath.length + 1));
            }
            else {
                result.push(path);
            }
        }

        return result;

    }

    function selectTarget() {

        // TODO

    }

    function selectVariant() {

        // TODO

    }

    function updateStatusBarItem(statusBarItem:StatusBarItem, title:String, description:String, command:String) {

        // Update/add status bar item
        if (statusBarItem == null) {
            numStatusBars++;
            statusBarItem = Vscode.window.createStatusBarItem(Left, -numStatusBars); // Ideally, we would want to make priority configurable
            context.subscriptions.push(statusBarItem);
        }
        
        statusBarItem.text = "[ " + title + " ]";
        statusBarItem.tooltip = description != null ? description : '';
        statusBarItem.command = command;
        statusBarItem.show();

        return statusBarItem;

    }

    /*
    function setChooserIndex(targetIndex:Int) {

        if (!checkWorkspaceFolder()) {
            return;
        }

        chooserIndex = targetIndex;

        var item = Json.parse(Json.stringify(listContent.items[chooserIndex]));

        // Merge with base item
        if (listContent.baseItem != null) {
            for (key in Reflect.fields(listContent.baseItem)) {
                if (!Reflect.hasField(item, key)) {
                    Reflect.setField(item, key, Reflect.field(listContent.baseItem, key));
                }
            }
        }

        // Add chooser index
        item.chooserIndex = chooserIndex;
        
        // Check if there is an onSelect command
        var onSelect:Dynamic = null;
        if (item != null) {
            onSelect = item.onSelect;
            if (onSelect != null) {
                Reflect.deleteField(item, "onSelect");
            }
        }

        // Update tasks.json
        if (item != null) {
            File.saveContent(tasksPath, Json.stringify(item, null, "    "));
        }

        // Run onSelect command, if any
        if (onSelect != null) {
            var args:Array<String> = onSelect.args;
            if (args == null) args = [];
            var showError = onSelect.showError;
            var proc = ChildProcess.spawn(onSelect.command, args, {cwd: getRootPath()});
            proc.stdout.on('data', function(data) {
                js.Node.process.stdout.write(data);
            });
            proc.stderr.on('data', function(data) {
                js.Node.process.stderr.write(data);
            });
            proc.on('close', function(code) {
                if (code != 0 && showError) {
                    Vscode.window.showErrorMessage("Failed run onSelect command: exited with code " + code);
                }
            });
        }

    }
    */

/// Internal helpers

    function getRootPath():String {

        return Vscode.workspace.workspaceFolders[0].uri.path;

    }

    function checkWorkspaceFolder():Bool {

        if (Vscode.workspace.workspaceFolders.length == 0) {
            Console.warn('No workspace root available. Did you open a folder?');
            return false;
        }

        return true;

    }

    function command(cmd:String, ?args:Array<String>, ?options:{?cwd:String, ?showError:Bool}, ?done:Int->String->String->Void):Void {

        if (args == null) args = [];

        var cwd = getRootPath();
        var showError = false;

        if (options != null) {
            if (options.cwd != null) {
                cwd = options.cwd;
            }
            if (options.showError != null) {
                showError = options.showError;
            }
        }

        var outStr = '';
        var errStr = '';

        var proc = ChildProcess.spawn(cmd, args, {cwd: cwd});

        proc.stdout.on('data', function(data) {
            outStr += data;
        });
        proc.stderr.on('data', function(data) {
            errStr += data;
        });

        proc.on('close', function(code) {
            if (code != 0 && showError) {
                var cmdStr = cmd;
                if (args.length > 0) {
                    cmdStr += ' ' + args.join(' ');
                }
                Vscode.window.showErrorMessage('Failed to run command: `$cmdStr` (code=' + code + ')');
            }

            if (done != null) {
                done(code, outStr, errStr);
                done = null;
            }
        });

    }

}
