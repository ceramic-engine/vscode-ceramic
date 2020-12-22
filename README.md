# Ceramic with Visual Studio Code

An extension to use ceramic engine with Visual Studio Code.

Auto-detects the presence of `ceramic.yml` file in project and adds options in status bar to choose build config:

![status bar with ceramic options](images/status-bar.png)

Click to choose **target** and **variant**. Then run build task (default shortcut: `CMD/CTRL+SHIFT+B`).

The extension auto-updates `.vscode/tasks.json` file as well as `completion.hxml` as needed to let [Haxe extension](https://marketplace.visualstudio.com/items?itemName=nadako.vshaxe) provide proper code completion.

More info about ceramic: https://github.com/ceramic-engine/ceramic
