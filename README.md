# Ceramic with Visual Studio Code

An extension to use ceramic engine with Visual Studio Code.

Auto-detects the presence of `ceramic.yml` file in project and adds options in status bar to choose build config:

![status bar with ceramic options](images/status-bar.png)

Click to choose **target** and **variant**. Then run build task (default shortcut: `CMD/CTRL+SHIFT+B`). The extension provides a `ceramic: active configuration` task. You can set it as default using command palette's `Configure Default Build Task`.

A `completion.hxml` is automatically updated by ceramic at the root of your workspace so that [Haxe extension](https://marketplace.visualstudio.com/items?itemName=nadako.vshaxe) provides proper code completion for your current project.

More info about ceramic: https://github.com/ceramic-engine/ceramic
