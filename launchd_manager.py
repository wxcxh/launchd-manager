#!/usr/bin/env python3

import os
import plistlib
import subprocess
import tkinter as tk
from pathlib import Path
from tkinter import messagebox, ttk


LAUNCH_AGENTS_DIR = Path.home() / "Library" / "LaunchAgents"


def run_command(args):
    return subprocess.run(args, capture_output=True, text=True)


def read_plist(path):
    with path.open("rb") as fh:
        return plistlib.load(fh)


def write_plist(path, data):
    with path.open("wb") as fh:
        plistlib.dump(data, fh, sort_keys=False)


class LaunchAgentManager:
    def __init__(self, root):
        self.root = root
        self.root.title("Launchd 定时任务管理")
        self.root.geometry("980x620")

        self.agents = []
        self.selected_agent = None

        self._build_ui()
        self.refresh_agents()

    def _build_ui(self):
        self.root.columnconfigure(0, weight=3)
        self.root.columnconfigure(1, weight=2)
        self.root.rowconfigure(0, weight=1)

        left = ttk.Frame(self.root, padding=12)
        left.grid(row=0, column=0, sticky="nsew")
        left.columnconfigure(0, weight=1)
        left.rowconfigure(1, weight=1)

        right = ttk.Frame(self.root, padding=12)
        right.grid(row=0, column=1, sticky="nsew")
        right.columnconfigure(1, weight=1)

        header = ttk.Frame(left)
        header.grid(row=0, column=0, sticky="ew", pady=(0, 8))
        header.columnconfigure(0, weight=1)
        ttk.Label(header, text="用户 LaunchAgents", font=("Helvetica", 16, "bold")).grid(
            row=0, column=0, sticky="w"
        )
        ttk.Button(header, text="刷新", command=self.refresh_agents).grid(row=0, column=1, sticky="e")

        columns = ("label", "time", "status")
        self.tree = ttk.Treeview(left, columns=columns, show="headings", height=24)
        self.tree.heading("label", text="任务")
        self.tree.heading("time", text="时间")
        self.tree.heading("status", text="状态")
        self.tree.column("label", width=320, anchor="w")
        self.tree.column("time", width=120, anchor="center")
        self.tree.column("status", width=100, anchor="center")
        self.tree.grid(row=1, column=0, sticky="nsew")
        self.tree.bind("<<TreeviewSelect>>", self.on_select)

        scrollbar = ttk.Scrollbar(left, orient="vertical", command=self.tree.yview)
        scrollbar.grid(row=1, column=1, sticky="ns")
        self.tree.configure(yscrollcommand=scrollbar.set)

        ttk.Label(right, text="任务详情", font=("Helvetica", 16, "bold")).grid(
            row=0, column=0, columnspan=2, sticky="w", pady=(0, 12)
        )

        self.fields = {}
        detail_rows = [
            ("名称", "label"),
            ("plist 路径", "path"),
            ("命令", "command"),
            ("时间", "schedule"),
            ("状态", "status"),
        ]

        for row_idx, (title, key) in enumerate(detail_rows, start=1):
            ttk.Label(right, text=title).grid(row=row_idx, column=0, sticky="nw", padx=(0, 8), pady=4)
            value = tk.Text(right, width=36, height=2, wrap="word")
            value.grid(row=row_idx, column=1, sticky="ew", pady=4)
            value.configure(state="disabled")
            self.fields[key] = value

        time_row = len(detail_rows) + 1
        ttk.Label(right, text="修改每日时间").grid(row=time_row, column=0, sticky="w", padx=(0, 8), pady=(16, 4))
        time_editor = ttk.Frame(right)
        time_editor.grid(row=time_row, column=1, sticky="w", pady=(16, 4))
        self.hour_var = tk.StringVar()
        self.minute_var = tk.StringVar()
        ttk.Entry(time_editor, textvariable=self.hour_var, width=5).grid(row=0, column=0)
        ttk.Label(time_editor, text=":").grid(row=0, column=1, padx=4)
        ttk.Entry(time_editor, textvariable=self.minute_var, width=5).grid(row=0, column=2)
        ttk.Button(time_editor, text="保存时间", command=self.save_time).grid(row=0, column=3, padx=(12, 0))

        button_row = time_row + 1
        actions = ttk.Frame(right)
        actions.grid(row=button_row, column=0, columnspan=2, sticky="ew", pady=(20, 8))
        actions.columnconfigure((0, 1, 2, 3), weight=1)
        ttk.Button(actions, text="立即执行", command=self.run_now).grid(row=0, column=0, sticky="ew", padx=4)
        ttk.Button(actions, text="启用", command=self.enable_agent).grid(row=0, column=1, sticky="ew", padx=4)
        ttk.Button(actions, text="停用", command=self.disable_agent).grid(row=0, column=2, sticky="ew", padx=4)
        ttk.Button(actions, text="打开 plist 目录", command=self.open_launchagents_dir).grid(
            row=0, column=3, sticky="ew", padx=4
        )

        self.status_var = tk.StringVar(value="准备就绪")
        ttk.Label(
            self.root,
            textvariable=self.status_var,
            relief="sunken",
            anchor="w",
            padding=(10, 6),
        ).grid(row=1, column=0, columnspan=2, sticky="ew")

    def set_text_field(self, key, value):
        field = self.fields[key]
        field.configure(state="normal")
        field.delete("1.0", "end")
        field.insert("1.0", value)
        field.configure(state="disabled")

    def refresh_agents(self):
        self.agents = self.load_agents()
        selected_path = self.selected_agent["path"] if self.selected_agent else None
        self.tree.delete(*self.tree.get_children())

        selected_item = None
        for idx, agent in enumerate(self.agents):
            item_id = str(idx)
            self.tree.insert("", "end", iid=item_id, values=(agent["label"], agent["time"], agent["status"]))
            if agent["path"] == selected_path:
                selected_item = item_id

        if selected_item is not None:
            self.tree.selection_set(selected_item)
            self.tree.focus(selected_item)
            self.on_select()
        elif self.agents:
            self.tree.selection_set("0")
            self.tree.focus("0")
            self.on_select()
        else:
            self.selected_agent = None
            for key in self.fields:
                self.set_text_field(key, "")
            self.hour_var.set("")
            self.minute_var.set("")

        self.status_var.set(f"已加载 {len(self.agents)} 个 LaunchAgent")

    def load_agents(self):
        launchctl = run_command(["launchctl", "list"])
        active_labels = set()
        for line in launchctl.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 3:
                active_labels.add(parts[-1])

        agents = []
        for path in sorted(LAUNCH_AGENTS_DIR.glob("*.plist")):
            try:
                plist = read_plist(path)
            except Exception as exc:
                agents.append(
                    {
                        "label": path.stem,
                        "path": str(path),
                        "command": f"读取失败: {exc}",
                        "time": "-",
                        "status": "损坏",
                    }
                )
                continue

            label = plist.get("Label", path.stem)
            schedule = plist.get("StartCalendarInterval", {})
            hour = schedule.get("Hour")
            minute = schedule.get("Minute")
            time_text = f"{hour:02d}:{minute:02d}" if isinstance(hour, int) and isinstance(minute, int) else "-"
            args = plist.get("ProgramArguments", [])
            command = " ".join(args) if args else plist.get("Program", "")
            agents.append(
                {
                    "label": label,
                    "path": str(path),
                    "command": command or "-",
                    "time": time_text,
                    "schedule": time_text,
                    "status": "已启用" if label in active_labels else "未启用",
                }
            )
        return agents

    def on_select(self, _event=None):
        selection = self.tree.selection()
        if not selection:
            return

        agent = self.agents[int(selection[0])]
        self.selected_agent = agent
        self.set_text_field("label", agent["label"])
        self.set_text_field("path", agent["path"])
        self.set_text_field("command", agent["command"])
        self.set_text_field("schedule", agent["schedule"])
        self.set_text_field("status", agent["status"])

        if agent["time"] != "-":
            hour, minute = agent["time"].split(":")
            self.hour_var.set(hour)
            self.minute_var.set(minute)
        else:
            self.hour_var.set("")
            self.minute_var.set("")

    def require_selection(self):
        if self.selected_agent:
            return True
        messagebox.showinfo("未选择任务", "请先从左侧列表选择一个 LaunchAgent。")
        return False

    def save_time(self):
        if not self.require_selection():
            return

        try:
            hour = int(self.hour_var.get())
            minute = int(self.minute_var.get())
        except ValueError:
            messagebox.showerror("时间格式错误", "请输入数字格式的小时和分钟。")
            return

        if not (0 <= hour <= 23 and 0 <= minute <= 59):
            messagebox.showerror("时间范围错误", "小时范围是 0-23，分钟范围是 0-59。")
            return

        path = Path(self.selected_agent["path"])
        plist = read_plist(path)
        plist["StartCalendarInterval"] = {"Hour": hour, "Minute": minute}
        write_plist(path, plist)

        self._reload_agent(path)
        self.refresh_agents()
        self.status_var.set(f"已更新 {self.selected_agent['label']} 的执行时间为 {hour:02d}:{minute:02d}")

    def _reload_agent(self, path):
        uid = str(os.getuid())
        run_command(["launchctl", "bootout", f"gui/{uid}", str(path)])
        result = run_command(["launchctl", "bootstrap", f"gui/{uid}", str(path)])
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or "重新加载 LaunchAgent 失败")

    def enable_agent(self):
        if not self.require_selection():
            return
        try:
            self._reload_agent(Path(self.selected_agent["path"]))
        except Exception as exc:
            messagebox.showerror("启用失败", str(exc))
            return
        self.refresh_agents()
        self.status_var.set(f"已启用 {self.selected_agent['label']}")

    def disable_agent(self):
        if not self.require_selection():
            return
        uid = str(os.getuid())
        result = run_command(["launchctl", "bootout", f"gui/{uid}", self.selected_agent["path"]])
        if result.returncode != 0:
            messagebox.showerror("停用失败", result.stderr.strip() or "无法停用该任务")
            return
        self.refresh_agents()
        self.status_var.set(f"已停用 {self.selected_agent['label']}")

    def run_now(self):
        if not self.require_selection():
            return

        path = Path(self.selected_agent["path"])
        plist = read_plist(path)
        args = plist.get("ProgramArguments", [])
        program = plist.get("Program")

        if args:
            result = run_command(args)
        elif program:
            result = run_command([program])
        else:
            messagebox.showerror("立即执行失败", "这个 LaunchAgent 没有可执行命令。")
            return

        if result.returncode != 0:
            messagebox.showerror("立即执行失败", result.stderr.strip() or "命令执行失败")
            return

        self.status_var.set(f"已执行 {self.selected_agent['label']}")
        messagebox.showinfo("执行完成", f"{self.selected_agent['label']} 已执行。")

    def open_launchagents_dir(self):
        result = run_command(["open", str(LAUNCH_AGENTS_DIR)])
        if result.returncode != 0:
            messagebox.showerror("打开目录失败", result.stderr.strip() or "无法打开 LaunchAgents 目录")


def main():
    root = tk.Tk()
    ttk.Style().theme_use("clam")
    LaunchAgentManager(root)
    root.mainloop()


if __name__ == "__main__":
    main()
