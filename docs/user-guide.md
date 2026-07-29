# Python 离线环境安装指南（新手版）

这份指南适合第一次接触 Python 的用户。按照下面的步骤操作即可，不需要提前安装
Python，也不需要管理员权限或网络。

适用电脑：Windows 10 或 Windows 11，64 位系统。

## 一、安装前准备

请先确认电脑上有至少 **2 GB 可用空间**，并且下面两个文件放在同一个文件夹中：

- `python-runtime-installer-0.1.0-windows-x64-unsigned.exe`：安装程序
- `SHA256SUMS.txt`：用于确认安装程序没有损坏

安装文件未签名，因此请只使用公司、学校或其他可信人员提供的文件，不要从陌生网站下载。

### 检查安装文件

这一步只需要做一次。如果不会操作，可以请提供安装文件的人协助。

1. 打开存放上述两个文件的文件夹。
2. 点击文件夹顶部的地址栏，输入 `powershell`，然后按回车键。
3. 依次复制下面两行命令，每复制一行就按一次回车键：

```powershell
Get-FileHash .\python-runtime-installer-0.1.0-windows-x64-unsigned.exe -Algorithm SHA256
Get-Content .\SHA256SUMS.txt
```

第一条命令会在 `Hash` 下方显示一串很长的字母和数字，第二条命令会在一行开头显示
另一串。确认这两串内容完全相同后，才可以继续安装。如果不相同，请不要运行安装程序，
并重新获取文件。

## 二、开始安装

1. 双击 `python-runtime-installer-0.1.0-windows-x64-unsigned.exe`。
2. 选择“简体中文”。
3. 按照窗口提示继续，等待安装完成。
4. 看到安装成功的提示后，点击“完成”。

安装期间请不要关闭安装窗口。整个过程不需要联网，也不需要选择安装位置。

如果 Windows 显示“Windows 已保护你的电脑”，请先确认文件来自可信来源，并且上一节的
两串校验内容完全相同。确认无误后，点击“更多信息”→“仍要运行”。

## 三、确认是否安装成功

1. 按一下键盘上的 Windows 键。
2. 搜索并打开 **Open Python Environment Terminal**。
3. 在打开的黑色窗口中输入下面的命令，然后按回车键：

```bat
python --version
```

如果看到下面的内容，说明安装成功：

```text
Python 3.13.14
```

以后使用这个 Python 环境时，也请先打开 **Open Python Environment Terminal**。
在普通的“命令提示符”或 PowerShell 中输入 `python`，可能会提示找不到命令，这是正常现象。

## 四、试着运行第一行 Python 代码

在 **Open Python Environment Terminal** 窗口中输入：

```bat
python
```

按回车键后，再输入：

```python
print("Hello, Python!")
```

如果屏幕显示 `Hello, Python!`，说明 Python 可以正常使用。

退出时输入：

```python
exit()
```

## 五、运行自己的 Python 文件

1. 把 Python 文件（例如 `hello.py`）保存在“文档”或“桌面”等容易找到的位置。
2. 打开 **Open Python Environment Terminal**。
3. 输入 `python`，再输入一个空格。
4. 用鼠标把 `hello.py` 文件拖进黑色窗口。
5. 按回车键运行。

最终显示的命令大致如下：

```bat
python "C:\Users\你的用户名\Documents\hello.py"
```

请把自己的代码和数据保存在“文档”或“桌面”等位置，不要放进 Python Runtime Installer
的安装文件夹。

## 六、遇到问题怎么办

### 输入 `python` 后提示找不到命令

请关闭当前窗口，然后从开始菜单重新打开 **Open Python Environment Terminal**。

### 安装失败或 Python 无法运行

重新双击原来的安装程序。安装程序会自动检查并修复环境。

如果仍然失败，请在开始菜单搜索并打开 **Open Installation Logs**，把最新的日志文件发给
技术支持。日志只保存在本机，不会自动上传。

### 可以自己安装其他 Python 软件包吗

不建议在这个环境中运行 `pip install`。修复或升级时，自己添加的软件包会被清除。
如需额外软件包，请联系为你提供安装程序的技术人员。

## 七、卸载

方法一：按 Windows 键，搜索并打开 **Uninstall Python Runtime Installer**。

方法二：打开 Windows“设置”→“应用”→“已安装的应用”，找到
**Python Runtime Installer**，然后点击“卸载”。

卸载后，安装日志会继续保留，方便技术人员排查以前的问题。
