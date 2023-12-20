package;

import haxe.Json;
import haxe.SysTools;
import haxe.Timer;
import haxe.io.Path;
import js.html.Console;
import js.node.ChildProcess;
import sys.FileSystem;
import sys.io.File;
import tracker.DefaultBackend;
import tracker.Entity;
import tracker.Model;
import tracker.Tracker;
import vscode.CancellationToken;
import vscode.Disposable;
import vscode.ExtensionContext;
import vscode.FileSystemWatcher;
import vscode.ProviderResult;
import vscode.ShellExecution;
import vscode.StatusBarItem;
import vscode.Task;
import vscode.TaskDefinition;
import vscode.TaskGroup;
import vscode.TaskPanelKind;
import vscode.TaskRevealKind;
import vscode.TaskScope;

using StringTools;
using tracker.SaveModel;

typedef Vshaxe = Dynamic;

typedef IdeInfoTargetItem = {

    var name:String;

    var command:String;

    @:optional var args:Array<String>;

    /** The groups this task belongs to. */
    @:optional var groups:Array<String>;

    @:optional var select:IdeInfoTargetSelectItem;

    @:optional var cwd:String;

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

class TrackerBackend extends DefaultBackend {

    var context:ExtensionContext;

    public function new(context:ExtensionContext) {
        super();
        this.context = context;
    }

    override function saveString(key:String, str:String):Bool {
        context.workspaceState.update(key, str);
        return true;
    }

    override function appendString(key:String, str:String):Bool {
        var existing = context.workspaceState.get(key);
        if (existing == null) {
            context.workspaceState.update(key, str);
        }
        else {
            context.workspaceState.update(key, existing + str);
        }
        return true;
    }

    override function readString(key:String):String {
        var str = context.workspaceState.get(key);
        return str;
    }

}

class VscodeCeramic extends Model {

/// Internal

    static var RE_NORMALIZED_WINDOWS_PATH_PREFIX = ~/^\/[a-zA-Z]:\//;

/// Exposed

    static var instance:VscodeCeramic = null;

    @:expose("activate")
    static function activate(context:ExtensionContext) {

        Timer.delay(function() {
            // If seems the delay is necessary to prevent some weird error?
            instance = new VscodeCeramic(context);
        }, 100);

    }

    private inline function getVshaxe():Vshaxe
    {
        return Vscode.extensions.getExtension("nadako.vshaxe").exports;
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

    var availableTargets:Array<String> = [];

    var availableVariants:Array<String> = [];

    var lastTasksJson:String = null;

    var ceramicToolsPath:String = null;

    var displayArgsProvider:CeramicDisplayArgsProvider = null;

    var displayArgsProviderDisposable:Disposable = null;

    @observe var ideTargets:Array<IdeInfoTargetItem> = null;

    @observe var ideVariants:Array<IdeInfoVariantItem> = null;

    @serialize var selectedCeramicProject:String = null;

    @serialize var selectedTarget:String = null;

    @serialize var selectedVariant:String = null;

/// Computed values

    @compute function selectedTargetInfo():IdeInfoTargetItem {
        var name = selectedTarget;
        var result = null;

        if (ideTargets != null) {
            for (item in ideTargets) {
                if (item.name == name) {
                    result = item;
                    break;
                }
            }
        }

        return result;

    }

    @compute function selectedVariantInfo():IdeInfoVariantItem {

        var name = selectedVariant;
        var result = null;
        var targetInfo = this.selectedTargetInfo;

        if (ideVariants != null) {
            for (variantInfo in ideVariants) {
                if (variantInfo.name == name) {
                    if (variantInfo.group == null || (targetInfo != null && targetInfo.groups != null && targetInfo.groups.indexOf(variantInfo.group) != -1)) {
                        result = variantInfo;
                        break;
                    }
                }
            }
        }

        return result;

    }

    @compute function tasksJsonString():Null<String> {

        var selectedCeramicProject = this.selectedCeramicProject;
        if (selectedCeramicProject == null) {
            return null;
        }

        var selectedTarget = this.selectedTarget;
        if (selectedTarget == null) {
            return null;
        }

        var selectedTargetInfo = this.selectedTargetInfo;
        if (selectedTargetInfo == null) {
            return null;
        }

        var selectedVariantInfo = this.selectedVariantInfo;

        var tasks:Dynamic = {};

        var displayName = selectedTarget;
        var description = '';

        if (selectedTargetInfo.command != null) {
            description += selectedTargetInfo.command;
            if (selectedTargetInfo.args != null && selectedTargetInfo.args.length > 0) {
                description += ' ' + selectedTargetInfo.args.join(' ');
            }

            if (selectedVariantInfo != null) {
                if (selectedVariantInfo.args != null && selectedVariantInfo.args.length > 0) {
                    description += ' ' + selectedVariantInfo.args.join(' ');
                }
                if (selectedVariantInfo.name != null && selectedVariantInfo.name.trim() != '') {
                    displayName += ' (' + selectedVariantInfo.name + ')';
                }
            }
        }

        tasks.displayName = displayName;
        tasks.description = description;
        tasks.version = '2.0.0';

        var task:Dynamic = {};

        task.type = 'shell';
        task.label = 'build';
        task.command = selectedTargetInfo.command;
        var taskArgs:Array<String> = [];
        if (selectedTargetInfo.args != null) {
            taskArgs = [].concat(selectedTargetInfo.args);
        }
        else {
            taskArgs = [];
        }
        if (selectedVariantInfo != null) {
            if (selectedVariantInfo.args != null && selectedVariantInfo.args.length > 0) {
                for (arg in selectedVariantInfo.args) {
                    taskArgs.push(arg);
                }
            }
        }

        taskArgs = updateArgsCwd(selectedCeramicProject, selectedTargetInfo, taskArgs);

        task.args = taskArgs;
        task.presentation = {
            'echo': true,
            'reveal': 'always',
            'focus': false,
            'panel': 'shared'
        };
        task.group = {
            'kind': 'build',
            'isDefault': true
        };
        task.problemMatcher = "$haxe";
        task.runOptions = {
            'instanceLimit': 1
        }

        tasks.tasks = [task];

        return Json.stringify(tasks, null, '    ');

    }

    @compute function currentTaskCommand():String {

        var selectedCeramicProject = this.selectedCeramicProject;
        if (selectedCeramicProject == null) {
            return null;
        }

        var selectedTarget = this.selectedTarget;
        if (selectedTarget == null) {
            return null;
        }

        var selectedTargetInfo = this.selectedTargetInfo;
        if (selectedTargetInfo == null) {
            return null;
        }

        return selectedTargetInfo.command;

        var taskArgs:Array<String> = [];
        if (selectedTargetInfo.args != null) {
            taskArgs = [].concat(selectedTargetInfo.args);
        }
        else {
            taskArgs = [];
        }
        if (selectedVariantInfo != null) {
            if (selectedVariantInfo.args != null && selectedVariantInfo.args.length > 0) {
                for (arg in selectedVariantInfo.args) {
                    taskArgs.push(arg);
                }
            }
        }

        taskArgs = updateArgsCwd(selectedCeramicProject, selectedTargetInfo, taskArgs);

    }

    @compute function currentTaskArgs():Array<String> {

        var selectedCeramicProject = this.selectedCeramicProject;
        if (selectedCeramicProject == null) {
            return null;
        }

        var selectedTarget = this.selectedTarget;
        if (selectedTarget == null) {
            return null;
        }

        var selectedTargetInfo = this.selectedTargetInfo;
        if (selectedTargetInfo == null) {
            return null;
        }

        var taskArgs:Array<String> = [];
        if (selectedTargetInfo.args != null) {
            taskArgs = [].concat(selectedTargetInfo.args);
        }
        else {
            taskArgs = [];
        }
        if (selectedVariantInfo != null) {
            if (selectedVariantInfo.args != null && selectedVariantInfo.args.length > 0) {
                for (arg in selectedVariantInfo.args) {
                    taskArgs.push(arg);
                }
            }
        }

        taskArgs = updateArgsCwd(selectedCeramicProject, selectedTargetInfo, taskArgs);

        return taskArgs;

    }

/// Lifecycle

    function new(context:ExtensionContext) {

        super();

        this.context = context;

        initData();

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

        resolveCeramicToolsPath(function() {

            patchHaxeExecutableAndCompletionSettings();
            loadCeramicContext();
            initTaskProvider();
        });

    }

    function resolveCeramicToolsPath(next:Void->Void) {

        command('ceramic', ['path'], { cwd: getRootPath() }, function(code, out, err) {
            if (out != null && out.trim().length != 0) {
                ceramicToolsPath = out.trim();
            }
            next();
        });

    }

    function initData() {

        Tracker.backend = new TrackerBackend(context);

        this.loadFromKey('ceramicUserInfo');
        this.autoSaveAsKey('ceramicUserInfo');

    }

/// Update settings.json

    function patchHaxeExecutableAndCompletionSettings():Void {

        try {
            var rootPath = getRootPath();
            var isWindows = (Sys.systemName() == 'Windows');
            if (isWindows)
                rootPath = fixWindowsPath(rootPath);
            var settingsPath = Path.join([rootPath, '.vscode/settings.json']);
            var settings = Json.parse(File.getContent(settingsPath));
            if (settings != null) {
                var patchedHaxeExecutable = false;
                var patchedCompletion = false;
                for (cmdName in ['haxe', 'haxelib']) {
                    var name = cmdName + '.executable';
                    if (Reflect.field(settings, name) != null) {
                        var cmdPath:String = Reflect.field(settings, name);
                        if (!Path.isAbsolute(cmdPath)) {
                            cmdPath = Path.join([rootPath, cmdPath]);
                        }
                        cmdPath = Path.normalize(cmdPath);
                        if (isWindows
                        && cmdPath.endsWith('tools/$cmdName')
                        && FileSystem.exists(Path.join([Path.directory(cmdPath), 'ceramic.js']))
                        ) {
                            // Add ".cmd" to command path
                            Reflect.setField(settings, name, Reflect.field(settings, name) + '.cmd');
                            patchedHaxeExecutable = true;
                        }
                        else if (!isWindows
                        && cmdPath.endsWith('tools/$cmdName.cmd')
                        && FileSystem.exists(Path.join([Path.directory(cmdPath), 'ceramic.js']))
                        ) {
                            // Remove ".cmd" to command path
                            var toReplace:String = Reflect.field(settings, name);
                            toReplace = toReplace.substring(0, toReplace.length - 4);
                            Reflect.setField(settings, name, toReplace);
                            patchedHaxeExecutable = true;
                        }
                        else if (
                            (cmdPath.endsWith('/tools/$cmdName') || cmdPath.endsWith('/tools/$cmdName.cmd'))
                            && !FileSystem.exists(cmdPath)) {
                            // Command path is invalid, but seems to point to a ceramic installation.
                            // Try to replace it with current ceramic installation.
                            if (ceramicToolsPath != null && FileSystem.exists(ceramicToolsPath)) {
                                var cmdPathParts = cmdPath.split('/');
                                var lastPart = cmdPathParts[cmdPathParts.length - 1];
                                if (isWindows && !lastPart.endsWith('.cmd')) {
                                    lastPart += '.cmd';
                                }
                                else if (!isWindows && lastPart.endsWith('.cmd')) {
                                    lastPart = lastPart.substring(0, lastPart.length - '.cmd'.length);
                                }
                                var relativeToolsPath = getRelativePath(ceramicToolsPath, rootPath);
                                Reflect.setField(settings, name, Path.join([
                                    relativeToolsPath,
                                    lastPart
                                ]));
                            }
                            else {
                                // If no ceramic installation known, simply remove the fields
                                Reflect.deleteField(settings, name);
                            }
                            patchedHaxeExecutable = true;
                        }
                    }
                }
                if (Reflect.hasField(settings, 'haxe.configurations')) {
                    Reflect.deleteField(settings, 'haxe.configurations');
                    patchedCompletion = true;
                }
                if (Reflect.hasField(settings, 'haxe.displayConfigurations')) {
                    Reflect.deleteField(settings, 'haxe.displayConfigurations');
                    patchedCompletion = true;
                }
                if (patchedHaxeExecutable || patchedCompletion) {
                    if (patchedHaxeExecutable) {
                        Vscode.window.showInformationMessage('Auto-patched .vscode/settings.json to point to proper haxe/haxelib binaries.');
                    }
                    File.saveContent(settingsPath, Json.stringify(settings, null, '    '));
                }
            }
        }
        catch (e1:Dynamic) {
            trace(e1);
            trace('Failed to patch haxe executable setting in .vscode/settings.json (maybe there is none yet)');
        }

    }

/// On select command

    function runOnSelectCommand():Void {

        var selectedTargetInfo = this.selectedTargetInfo;
        if (selectedTargetInfo == null)
            return;

        if (selectedTargetInfo.select == null || selectedTargetInfo.select.command == null)
            return;

        var args = [];
        if (selectedTargetInfo.select.args != null) {
            for (arg in selectedTargetInfo.select.args) {
                args.push(arg);
            }
        }

        var selectedVariantInfo = this.selectedVariantInfo;
        if (selectedVariantInfo != null && selectedVariantInfo.select != null) {
            if (selectedVariantInfo.select.args != null) {
                for (arg in selectedVariantInfo.select.args) {
                    args.push(arg);
                }
            }
        }

        args = updateArgsCwd(selectedCeramicProject, selectedTargetInfo, args);
        var cwd = getRootPath();
        cwd = extractArgsCwd(cwd, args, true);

        var completionHxmlPath = extractCompletionHxmlArg(args);

        var originalArgs = args;
        var hasDisplayArgsProvider = (displayArgsProvider != null);
        args = hasDisplayArgsProvider ? patchCompletionHxmlArgs(args) : args;

        trace('On select command: ${selectedTargetInfo.select.command} ${args.join(' ')}');
        command(
            selectedTargetInfo.select.command,
            args,
            {
                cwd: cwd
            },
            function(_, cmdOut, _) {
                if (hasDisplayArgsProvider && cmdOut != null && cmdOut.trim().length > 0) {
                    if (completionHxmlPath != null && FileSystem.exists(completionHxmlPath)) {
                        FileSystem.deleteFile(completionHxmlPath);
                    }
                    trace(cmdOut);

                    // Compatibility with older Ceramic version
                    if (cmdOut.startsWith('Updated ') && cmdOut.indexOf('--cwd ') != -1) {
                        cmdOut = cmdOut.substring(cmdOut.indexOf('--cwd '));
                    }

                    displayArgsProvider.update(cmdOut);
                }
                else {
                    untyped setTimeout(function() {
                        Vscode.commands.executeCommand('haxe.restartLanguageServer');
                    }, 1000);
                }
            }
        );

    }

    function findCompletionHxmlArgIndex(args:Array<String>) {

        var completionIndex = -1;

        for (i in 0...args.length) {
            var arg = args[i];
            if (arg.endsWith('completion.hxml') && i > 0 && (args[i-1] == '--output' || args[i-1] == '--hxml-output')) {
                completionIndex = i;
                break;
            }
        }

        return completionIndex;

    }

    function patchCompletionHxmlArgs(args:Array<String>, ?replacementSuffix:String) {

        var newArgs = [].concat(args);

        var completionIndex = findCompletionHxmlArgIndex(args);

        if (completionIndex > 0) {
            if (replacementSuffix != null) {
                newArgs[completionIndex] = newArgs[completionIndex] + replacementSuffix;
            }
            else {
                newArgs.splice(completionIndex - 1, 2);
            }
        }

        return newArgs;

    }

    function extractCompletionHxmlArg(args:Array<String>) {

        var completionIndex = findCompletionHxmlArgIndex(args);

        if (completionIndex > 0) {
            return args[completionIndex];
        }

        return null;

    }

/// Watch

    function watchCeramicProjectFiles():Void {

        if (!checkWorkspaceFolder()) {
            return;
        }

        var filePattern = '**/ceramic.yml';

        trace('File files... (pattern: $filePattern)');

        Vscode.workspace.findFiles(filePattern).then(function(result) {

            for (uri in result) {
                trace('Detect: $uri');
                createOrUpdateCeramicPath(uri.path);
            }

            watcher = Vscode.workspace.createFileSystemWatcher(filePattern, false, false, false);

            context.subscriptions.push(watcher.onDidChange(function(uri) {
                trace('Change: $uri');
                createOrUpdateCeramicPath(uri.path);
            }));
            context.subscriptions.push(watcher.onDidCreate(function(uri) {
                trace('Create: $uri');
                createOrUpdateCeramicPath(uri.path);
                checkExistingCeramicPaths();
            }));
            context.subscriptions.push(watcher.onDidDelete(function(uri) {
                trace('Delete: $uri');
                removeCeramicPath(uri.path);
            }));
            context.subscriptions.push(watcher);
        });

        watchingWorkspace = true;

    }

    function checkExistingCeramicPaths() {

        var isWindows = (Sys.systemName() == 'Windows');
        for (path in [].concat(availableCeramicProjects)) {
            var p = path;
            if (isWindows)
                p = fixWindowsPath(p);
            if (!FileSystem.exists(p)) {
                trace('Delete path: $path');
                removeCeramicPath(path);
            }
        }

    }

    function createOrUpdateCeramicPath(path:String) {

        if (availableCeramicProjects.indexOf(path) == -1) {
            availableCeramicProjects.push(path);
            sortAlphabetically(availableCeramicProjects);
        }
        updateFromSelectedCeramicProject();

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

        if (selectCeramicProject == null) {
            disposeDisplayArgsProvider();
        }
        else {
            initDisplayArgsProvider();
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

        trace('Fetch targets and variants: $selectedCeramicProject');

        if (fetchingTargets) {
            shouldFetchAgain = true;
            return;
        }
        fetchingTargets = true;

        command('ceramic', ['ide', 'info', '--print-split-lines'], { cwd: Path.directory(selectedCeramicProject), showError: true }, function(code, out, err) {
            fetchingTargets = false;

            if (shouldFetchAgain) {
                shouldFetchAgain = false;
                fetchTargets();
                return;
            }

            var data = Json.parse(out);
            var ideTargets:Array<IdeInfoTargetItem> = data.ide.targets;
            var ideVariants:Array<IdeInfoVariantItem> = data.ide.variants;

            availableTargets = [];
            for (ideTarget in ideTargets) {
                if (ideTarget.args != null) {
                    ideTarget.args = patchCompletionHxmlArgs(ideTarget.args);
                }
                availableTargets.push(ideTarget.name);
            }

            for (ideVariant in ideVariants) {
                if (ideVariant.args != null) {
                    ideVariant.args = patchCompletionHxmlArgs(ideVariant.args);
                }
            }

            this.ideTargets = ideTargets;
            this.ideVariants = ideVariants;

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

        trace('Update from selected target title=$title available=$availableTargets');

        targetStatusBarItem = updateStatusBarItem(
            targetStatusBarItem,
            '▶︎ ' + title,
            description,
            'ceramic.select-target'
        );

        if (selectedTarget != null) {
            computeVariants();
        }

    }

    function computeVariants():Void {

        var variants:Array<String> = [];

        var targetInfo = selectedTargetInfo;

        if (targetInfo != null) {
            var groups:Array<String> = targetInfo.groups;
            for (variantInfo in ideVariants) {
                if (variantInfo.group == null || (groups != null && groups.indexOf(variantInfo.group) != -1)) {
                    variants.push(variantInfo.name);
                }
            }
        }

        availableVariants = variants;

        updateFromSelectedVariant();

    }

    function updateFromSelectedVariant() {

        if (selectedVariant != null && availableVariants.indexOf(selectedVariant) == -1) {
            selectedVariant = null;
        }

        if (selectedVariant == null && availableVariants.length > 0) {
            selectedVariant = availableVariants[0];
        }

        var title = selectedVariant != null ? selectedVariant : '-';
        var description = selectedVariant != null ? selectedVariant : 'No variant selected';

        trace('Update from selected variant title=$title available=$availableVariants');

        variantStatusBarItem = updateStatusBarItem(
            variantStatusBarItem,
            'variant: ' + title,
            description,
            'ceramic.select-variant'
        );

        // Run every time project/target/variant changes
        runOnSelectCommand();

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

        if (!watchingWorkspace)
            watchCeramicProjectFiles();

    }

    function selectCeramicProject() {

        var pickItems:Array<Dynamic> = [];
        var index = 0;
        var availableCeramicProjects = [].concat(this.availableCeramicProjects);
        var shortPaths = computeShortPaths(availableCeramicProjects);
        for (path in availableCeramicProjects) {
            pickItems.push({
                label: shortPaths[index],
                description: cleanAbsolutePath(path),
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

    function updateArgsCwd(selectedCeramicProject:String, selectedTargetInfo:IdeInfoTargetItem, args:Array<String>):Array<String> {

        args = [].concat(args);

        var baseCwd = null;
        if (selectedTargetInfo != null && selectedTargetInfo.cwd != null) {
            baseCwd = selectedTargetInfo.cwd;
        }

        var targetCwd = null;

        var cwdIndex = args.indexOf('--cwd');
        if (cwdIndex != -1) {
            targetCwd = args[cwdIndex + 1];
            if (baseCwd != null && !Path.isAbsolute(targetCwd)) {
                targetCwd = Path.normalize(Path.join([baseCwd, targetCwd]));
            }
        }

        if (selectedCeramicProject != null) {
            if (targetCwd == null) {
                targetCwd = Path.directory(selectedCeramicProject);
                if (baseCwd != null) {
                    if (Path.isAbsolute(baseCwd)) {
                        targetCwd = baseCwd;
                    }
                    else {
                        targetCwd = Path.normalize(Path.join([targetCwd, baseCwd]));
                    }
                }
                if (Path.normalize(targetCwd) != Path.normalize(getRootPath())) {
                    args.push('--cwd');
                    args.push(computeShortPath(targetCwd));
                }
                else {
                    targetCwd = null;
                }

                if (targetCwd != null) {
                    // Update hxml output
                    var hxmlOutputTarget = getRootPath();
                    var hxmlOutputIndex = args.indexOf('--hxml-output');
                    if (hxmlOutputIndex != -1) {
                        args[hxmlOutputIndex + 1] = Path.join([hxmlOutputTarget, 'completion.hxml']);
                    }
                    else {
                        // Match `ceramic hxml --output completion.hxml`
                        var hxmlIndex = args.indexOf('hxml');
                        var outputIndex = args.indexOf('--output');
                        if (hxmlIndex == 1 && outputIndex != -1 && args[outputIndex + 1] == 'completion.hxml') {
                            args[outputIndex + 1] = Path.join([hxmlOutputTarget, 'completion.hxml']);
                        }
                    }
                }
            }
        }

        return args;

    }

    function computeShortPath(path:String):String {

        var rootPath = getRootPath();

        if (rootPath != null && path.toLowerCase().startsWith(rootPath.toLowerCase())) {
            return path.substring(rootPath.length + 1);
        }
        else if (Sys.systemName() == 'Windows' && rootPath.startsWith('/')) {
            return rootPath.substring(1);
        }
        else {
            return path;
        }

    }

    function computeShortPaths(paths:Array<String>):Array<String> {

        var result = [];

        for (path in paths) {
            result.push(computeShortPath(path));
        }

        return result;

    }

    function cleanAbsolutePath(path:String):String {

        if (Sys.systemName() == 'Windows') {
            if (path != null && path.startsWith('/') && RE_NORMALIZED_WINDOWS_PATH_PREFIX.match(path)) {
                return path.substring(1);
            }
        }

        return path;

    }

    function selectTarget() {

        var pickItems:Array<Dynamic> = [];
        var index = 0;
        var availableTargets = [].concat(this.availableTargets);
        for (target in availableTargets) {
            var description = '';
            for (targetInfo in ideTargets) {
                if (target == targetInfo.name) {
                    description = targetInfo.command;
                    if (targetInfo.args != null && targetInfo.args.length > 0) {
                        description += ' ' + targetInfo.args.join(' ');
                    }
                }
            }
            pickItems.push({
                label: target,
                description: description,
                index: index,
            });
            index++;
        }

        // Put selected project at the top
        var selectedIndex = availableTargets.indexOf(selectedTarget);
        if (selectedIndex != -1) {
            var selectedItem = pickItems[selectedIndex];
            pickItems.splice(selectedIndex, 1);
            pickItems.unshift(selectedItem);
        }

        var placeHolder = 'Select target';

        Vscode.window.showQuickPick(pickItems, { placeHolder: placeHolder }).then(function(choice:Dynamic) {
            if (choice == null || choice.index == selectedIndex) {
                return;
            }

            try {
                selectedTarget = availableTargets[choice.index];
                updateFromSelectedTarget();
            }
            catch (e:Dynamic) {
                Vscode.window.showErrorMessage("Failed to select ceramic target: " + e);
                js.Node.console.error(e);
            }

        });

    }

    function selectVariant() {

        var pickItems:Array<Dynamic> = [];
        var index = 0;
        var availableVariants = [].concat(this.availableVariants);
        var targetInfo = selectedTargetInfo;
        for (variant in availableVariants) {
            var description = '';
            for (variantInfo in ideVariants) {
                if (variantInfo.name == variant) {
                    if (variantInfo.group == null || (targetInfo != null && targetInfo.groups != null && targetInfo.groups.indexOf(variantInfo.group) != -1)) {
                        if (variantInfo.args != null && variantInfo.args.length > 0) {
                            description += variantInfo.args.join(' ');
                            break;
                        }
                    }
                }
            }
            pickItems.push({
                label: variant,
                description: description,
                index: index,
            });
            index++;
        }

        // Put selected project at the top
        var selectedIndex = availableVariants.indexOf(selectedVariant);
        if (selectedIndex != -1) {
            var selectedItem = pickItems[selectedIndex];
            pickItems.splice(selectedIndex, 1);
            pickItems.unshift(selectedItem);
        }

        var placeHolder = 'Select variant';

        Vscode.window.showQuickPick(pickItems, { placeHolder: placeHolder }).then(function(choice:Dynamic) {
            if (choice == null || choice.index == selectedIndex) {
                return;
            }

            try {
                selectedVariant = availableVariants[choice.index];
                updateFromSelectedVariant();
            }
            catch (e:Dynamic) {
                Vscode.window.showErrorMessage("Failed to select ceramic variant: " + e);
                js.Node.console.error(e);
            }

        });

    }

    function updateStatusBarItem(statusBarItem:StatusBarItem, title:String, description:String, command:String) {

        // Update/add status bar item
        if (statusBarItem == null) {
            numStatusBars++;
            statusBarItem = Vscode.window.createStatusBarItem(Left, -numStatusBars); // Ideally, we would want to make priority configurable
            context.subscriptions.push(statusBarItem);
        }

        //statusBarItem.text = "[ " + title + " ]";
        statusBarItem.text = title;
        statusBarItem.tooltip = description != null ? description : '';
        statusBarItem.command = command;
        statusBarItem.show();

        return statusBarItem;

    }

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

    function fixWindowsPath(path:String):String {

        if (path != null && path.startsWith('/') && RE_NORMALIZED_WINDOWS_PATH_PREFIX.match(path)) {
            path = path.substring(1);
        }
        return path;

    }

    function fixWindowsArgsPaths(args:Array<String>):Void {

        // Remove absolute path leading slash on windows, if any
        // This let us accept absolute paths that start with `/c:/` instead of `c:/`
        // which could happen after joining/normalizing paths via node.js or vscode extension
        if (Sys.systemName() == 'Windows') {
            var i = 0;
            while (i + 1 < args.length) {
                if (args[i].startsWith('--')) {
                    var value = args[i + 1];
                    if (value != null && value.startsWith('/') && RE_NORMALIZED_WINDOWS_PATH_PREFIX.match(value)) {
                        args[i + 1] = value.substring(1);
                        i++;
                    }
                }
                i++;
            }
        }

    }

    function command(cmd:String, ?args:Array<String>, ?options:{?cwd:String, ?showError:Bool}, ?done:Int->String->String->Void):Void {

        if (args == null) args = [];
        else args = [].concat(args);

        fixWindowsArgsPaths(args);

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

        var execCommand = cmd;

        if (args.length > 0) {
            if (Sys.systemName() == 'Windows') {
                for (i in 0...args.length) {
                    execCommand += ' ' + SysTools.quoteWinArg(args[i], true);
                }
            }
            else {
                for (i in 0...args.length) {
                    execCommand += ' ' + SysTools.quoteUnixArg(args[i]);
                }
            }
        }

        if (Sys.systemName() == 'Windows') {
            if (cwd.charAt(0) == '/' && cwd.charAt(2) == ':') {
                cwd = cwd.substring(1);
            }
        }

        ChildProcess.exec(execCommand, {
            cwd: cwd
        },  function(err, stdout, stderr) {
            if (err != null && showError) {
                var cmdStr = cmd;
                if (args.length > 0) {
                    cmdStr += ' ' + args.join(' ');
                }
                Vscode.window.showErrorMessage('Failed to run command: `$cmdStr` (signal=' + err.signal + ' code=' + err.code + ')');
            }

            if (err != null) {
                trace(err);
            }

            outStr += stdout;
            errStr += stderr;

            if (done != null) {
                done(err != null ? err.code : 0, outStr, errStr);
                done = null;
            }
        });

        /*
        var proc = ChildProcess.spawn(cmd, args);

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
        */

    }

/// Task provider

    var taskProvider:Disposable;

    function initTaskProvider():Void {

        taskProvider = Vscode.tasks.registerTaskProvider('ceramic', {
            provideTasks: provideTasks,
            resolveTask: resolveTask
        });

    }

    /**
     * Provides tasks.
     * @param token A cancellation token.
     * @return an array of tasks
     */
    function provideTasks(?token:CancellationToken):ProviderResult<Array<Task>> {

        var task = createCeramicTask();

        return [task];

    }

    /**
     * Resolves a task that has no [`execution`](#Task.execution) set. Tasks are
     * often created from information found in the `tasks.json`-file. Such tasks miss
     * the information on how to execute them and a task provider must fill in
     * the missing information in the `resolveTask`-method. This method will not be
     * called for tasks returned from the above `provideTasks` method since those
     * tasks are always fully resolved. A valid default implementation for the
     * `resolveTask` method is to return `undefined`.
     *
     * @param task The task to resolve.
     * @param token A cancellation token.
     * @return The resolved task
     */
    function resolveTask(task:Task, ?token:CancellationToken):ProviderResult<Task> {

        return task;

    }

    function extractArgsCwd(cwd:String, args:Array<String>, updateArgs:Bool = false):String {

        var customCwdIndex = args.indexOf('--cwd');
        if (customCwdIndex != -1 && args.length > customCwdIndex + 1) {
            var customCwd = args[customCwdIndex + 1];
            if (!Path.isAbsolute(customCwd)) {
                customCwd = Path.join([cwd, customCwd]);
            }
            cwd = customCwd;
            if (updateArgs) {
                args.splice(customCwdIndex, 2);
            }
        }

        return cwd;

    }

    function createCeramicTask():Task {

        var cwd = getRootPath();

        var taskCommand = currentTaskCommand;
        var taskArgs = currentTaskArgs;
        if (taskArgs == null) {
            taskArgs = [];
        }
        else {
            taskArgs = [].concat(taskArgs);
        }
        if (taskCommand == null) {
            taskCommand = 'echo';
            taskArgs = ['No command defined'];
        }

        fixWindowsArgsPaths(taskArgs);

        cwd = extractArgsCwd(cwd, taskArgs, true);

        var execution = new ShellExecution(taskCommand, taskArgs, {
            cwd: cwd
        });

        var definition:TaskDefinition = {
            type: 'ceramic'
        };
        Reflect.setField(definition, 'args', 'active configuration');

        var problemMatchers = ["$haxe-absolute", "$haxe", "$haxe-error", "$haxe-trace"];

        var task = new Task(definition, TaskScope.Workspace, 'active configuration', 'ceramic', execution, problemMatchers);
        task.group = TaskGroup.Build;
        task.presentationOptions = {
            "echo": true,
            "reveal": TaskRevealKind.Always,
            "focus": false,
            "panel": TaskPanelKind.Shared
        };
        task.runOptions = cast {
            'instanceLimit': 1
        };

        return task;

    }

    function getRelativePath(absolutePath:String, relativeTo:String):String {

        var isWindows = Sys.systemName() == 'Windows';

        if (isWindows) {
            var driveA = Path.normalize(absolutePath).substr(0, 2).toLowerCase();
            var driveB = Path.normalize(relativeTo).substr(0, 2).toLowerCase();
            if (driveA.charAt(1) == ':' && driveB.charAt(1) == ':' && driveA != driveB) {
                // Path located on different drives, can't be relative
                return absolutePath;
            }
        }

        var fromParts = Path.normalize(relativeTo).substr(isWindows ? 3 : 1).split('/');
        var toParts = Path.normalize(absolutePath).substr(isWindows ? 3 : 1).split('/');

        var length:Int = cast Math.min(fromParts.length, toParts.length);
        var samePartsLength = length;
        for (i in 0...length) {
            if (fromParts[i] != toParts[i]) {
                samePartsLength = i;
                break;
            }
        }

        var outputParts = [];
        for (i in samePartsLength...fromParts.length) {
            outputParts.push('..');
        }

        outputParts = outputParts.concat(toParts.slice(samePartsLength));

        var result = outputParts.join('/');
        if (absolutePath.endsWith('/') && !result.endsWith('/')) {
            result += '/';
        }

        if (!result.startsWith('.')) result = './' + result;

        return result;

    }

/// Args provider

    function initDisplayArgsProvider() {

        if (displayArgsProvider == null) {
            var api = getVshaxe();
            displayArgsProvider = new CeramicDisplayArgsProvider(api, function(isProviderActive) {
                //
            });

            if (untyped !api) {
                trace("[warning] Haxe language server not available (using an incompatible vshaxe version)");
            }
            else
            {
                displayArgsProviderDisposable = api.registerDisplayArgumentsProvider("Ceramic", displayArgsProvider);
            }
        }

    }

    function disposeDisplayArgsProvider() {

        if (displayArgsProviderDisposable != null) {
            displayArgsProviderDisposable.dispose();
            displayArgsProviderDisposable = null;
            displayArgsProvider = null;
        }

    }

}

/// Display args provider

class CeramicDisplayArgsProvider
{
    public var description(default, never):String = "Ceramic project";
    public var parsedArguments(default, null):Array<String>;

    private var activationChangedCallback:Bool->Void;
    private var api:Vshaxe;
    private var arguments:String;

    private var updateArgumentsCallback:Array<String>->Void;

    public function new(api:Vshaxe, activationChangedCallback:Bool->Void)
    {
        this.api = api;
        this.activationChangedCallback = activationChangedCallback;
    }

    public function activate(provideArguments:Array<String>->Void):Void
    {
        updateArgumentsCallback = provideArguments;

        if (parsedArguments != null)
        {
            updateArguments();
        }

        activationChangedCallback(true);
    }

    public function deactivate():Void
    {
        updateArgumentsCallback = null;

        activationChangedCallback(false);
    }

    public function update(arguments:String):Void
    {
        if (this.arguments != arguments && api != null)
        {
            this.arguments = arguments;
            this.parsedArguments = api.parseHxmlToArguments(arguments);

            updateArguments();
        }
    }

    private function updateArguments()
    {
        if (updateArgumentsCallback != null)
        {
            updateArgumentsCallback(parsedArguments);
        }
    }

}
