# _bootstrap —— 离线依赖投放目录

如果 `pw_recon.py` 报错「无法 import palworld_save_tools」，而你的机器又不能
直接 `pip install`，就把依赖手动放到这个目录里，脚本会自动识别。

## 放法

去 https://github.com/cheahjs/palworld-save-tools/releases/latest
下载 release 压缩包（文件名类似 `palworld-save-tools.zip`），解压后你会看到
一个 `palworld_save_tools` 文件夹。

把**整个文件夹**复制进来，最终长这样：

```
tools/_bootstrap/
└─ palworld_save_tools/
   ├─ __init__.py
   ├─ archive.py
   ├─ gvas.py
   ├─ palsav.py
   ├─ paltypes.py
   ├─ rawdata/
   │  ├─ map_object.py
   │  ├─ map_model.py
   │  ├─ map_concrete_model.py
   │  └─ ...
   └─ ...
```

## 也支持的形式

脚本还会扫描这个目录下的 `*.whl` / `*.zip` / `*.tar.gz` 并自动解压：

```
tools/_bootstrap/
├─ palworld_save_tools-0.6.0-py3-none-any.whl
```

两种方式都可以，任选其一。

## 为什么需要这么麻烦

`pw_recon.py` 依赖第三方库才能把 GVAS 属性解码成 JSON。
如果你连这个也搞不定，先跑零依赖的 `tools/pw_sav_probe.py`，
它只用 Python 标准库，虽然读不出建筑数据的具体内容，但能确认文件结构。
