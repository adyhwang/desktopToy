extends Node2D
## 游戏生命周期接口（主程序约定，签名固定）
## 注意：不使用 class_name —— 各游戏包各自内置本文件，避免多包全局类名冲突
## 游戏主脚本通过 extends "res://games/<id>/scripts/game_base.gd" 继承

## 游戏内主动退出（如退出按钮），主程序收到后 stop_game 回启动界面
signal exit_requested

func start() -> void:
	pass


func stop() -> void:
	pass


func pause() -> void:
	pass  # 预留：难度/音效/皮肤自定义接口挂载点


func resume() -> void:
	pass  # 预留
