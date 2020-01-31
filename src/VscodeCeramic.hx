package;

import js.html.Console;
import sys.io.File;
import haxe.io.Path;
import haxe.Json;
import js.node.ChildProcess;

import vscode.ExtensionContext;
import vscode.StatusBarItem;
import vscode.FileSystemWatcher;

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

    var tasksPath:String;

    var listContent:Dynamic;

    var chooserIndex:Dynamic;

    var watcher:FileSystemWatcher;

    var targetStatusBarItem:StatusBarItem;

    var variantStatusBarItem:StatusBarItem;

    var numStatusBars:Int = 0;

    var availableCeramicProjects:Array<String> = [];

    var selectedCeramicProject:String = null;

/// Lifecycle

    function new(context:ExtensionContext) {

        this.context = context;

        context.subscriptions.push(Vscode.commands.registerCommand("ceramic.load", function() {
            loadCeramicContext();
        }));

        context.subscriptions.push(Vscode.commands.registerCommand("ceramic.select-target", function() {
            selectTarget();
        }));

        context.subscriptions.push(Vscode.commands.registerCommand("ceramic.select-variant", function() {
            selectVariant();
        }));

        loadCeramicContext();

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

        // TODO
        
    }

    function removeCeramicPath(path:String) {

        // TODO
        
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

    function selectTarget() {

        var pickItems:Array<Dynamic> = [];
        var index = 0;
        var items:Array<Dynamic> = listContent.items;
        for (item in items) {
            pickItems.push({
                label: (item.displayName != null ? item.displayName : 'Task #' + index),
                description: item.description != null ? item.description : '',
                index: index,
            });
            index++;
        }

        // Put selected task at the top
        if (chooserIndex > 0) {
            var selectedItem = pickItems[chooserIndex];
            pickItems.splice(chooserIndex, 1);
            pickItems.unshift(selectedItem);
        }

        var placeHolder = null;
        if (listContent.selectDescription != null) {
            placeHolder = listContent.selectDescription;
        } else {
            placeHolder = 'Select task';
        }

        Vscode.window.showQuickPick(pickItems, { placeHolder: placeHolder }).then(function(choice:Dynamic) {
            if (choice == null || choice.index == chooserIndex) {
                return;
            }
            
            try {
                setChooserIndex(choice.index);
            }
            catch (e:Dynamic) {
                Vscode.window.showErrorMessage("Failed to select task: " + e);
                js.Node.console.error(e);
            }

        });

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
