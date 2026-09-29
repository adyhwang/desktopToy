' DesktopToy 开发期启动器：双击运行，隐藏控制台窗口直接拉起引擎
' 注：--path 参数不支持含空格路径（启动器按空格重组参数）
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
base = fso.GetParentFolderName(WScript.ScriptFullName)
sh.Run """" & base & "\tools\godot\Godot_v4.7.2-stable_win64.exe"" --path """ & base & "\launcher""", 0, False
