# UniPalUI 接入探索（待办 5「方案②: 游戏内 UI 改键」）

> ## ⛔ 最终结论（2026-10-07）：**这条路走不通，已放弃；本项目改走「路③ 自建」**
>
> **一句话**: `UPI_RegisterMod` 要求"**由 `BPModLoaderMod` 生成的 BP `ModActor`**"（它自己的
> 日志 `Loading mod: … / … created through Mod Actor!` 就是它的注册方式）——
> **纯 Lua 没有这个对象，一调就崩**（`EXCEPTION_ACCESS_VIOLATION reading 0x70`）。
>
> **为得出这个结论，我们已排除的原因**（每一条都有实机证据，共 6 次可控崩溃）:
> | 已排除 | 证据 |
> |---|---|
> | 参数个数/顺序错 | `UE4SS_ObjectDump.txt`（"Generate BP SDK"）里的真实签名: 5 输入 + 2 输出 = 7 |
> | 出参写法错 | `Tried storing reference to a Lua table for an 'Out' parameter …` ⇒ 已改成"每个出参传一个表" |
> | `EnterPage` 传空串非法 | 改传 `"None"` 后仍崩 |
> | 对象不合格 | 用**它自己的** `SCML_CPP_NewObject(Outer, Class, out)` 造的正规 `UPI_ModObject_C`，仍崩 |
> | 时机太早（标题界面） | 加了 60 秒延时闸门、在**世界里**（`PL_MainWorld5`）调，仍崩 |
> | 我们根本调不到它的函数 | ❌ 反证: `SCML_CPP_SendToUE4SSLog(...)` **实测调用成功** ⇒ 调用链是通的 |
>
> **要重开这条路，只差一样东西**: 一个**提供 BP `ModActor` 的桥 pak**（需要 UE5.1 编辑器）。
> 相关开关（`unipal_*`）**默认全部关闭**；将来若拿到桥 pak，打开即可复验。
>
> **仍然有效的知识（写在下面，别丢）**:
> 1. **UE4SS 调 BP 函数的完整约定**（拿崩溃换来的）: ① 参数个数 = **输入 + 输出**；
>    ② **每个输出参数必须传一个 Lua 表**（传 `nil` 不是报错而是崩游戏）；③ 出参**按名字**回填
>    （例 `out.NewObject`）；④ 少传/多传**安全**（执行前报错）；⑤ 只有"全对"才真的执行。
> 2. **怎么拿真实签名**: UE4SS 控制台 → dumpers → **"Generate BP SDK"** →
>    `Mods\NativeMods\UE4SS\UE4SS_ObjectDump.txt`，按属性 `[o: N]` 偏移排序 = 参数顺序。
> 3. **本机 UE4SS 有两个树**: 活跃的是 `Mods\NativeMods\UE4SS\`；`Pal\Binaries\Win64\ue4ss\`
>    是惰性的（mod 装错地方 ⇒ `[SCML] … Register Timeout`）。

> **这份文档回答**: 「我们能不能用 UniPalUI 做游戏内改键？走到哪一步了？」
> 相关: `docs\项目状态与路线图.md` **§5.3b**（可行性核对，全是实据）、
> `docs\配置说明.md`（`unipal_probe` / `unipal_call_notif`）、
> 代码 `mod\PWProjection\Scripts\pwpr_unipal.lua`。

---

## 一、结论先行（截至 2026-10-06 晚，**SDK 已到手**）

> ★★ **重大进展**: 玩家找到了官方 **`UPI_SDK`**（`OtherMods\UPI_SDK v0.01.09 …`），
> 里面 `UPI_SDK - ReadMe.md`（33 KB）**带着完整 API 文档**（每个函数的参数名/类型/返回值）。
> 下面是**据此更正过的**结论。

| 问题 | 状态 |
|---|---|
| UniPalUI 是什么 | **DLL + pak 蓝图**的框架（`Mods\UniPalUI\dlls\main.dll` + `Content\Paks\LogicMods\UniPalUI.pak`）—— **不是 Lua 框架**，不能 `require` |
| 装了它会不会阻塞我们 | **不会**（不 require、只"存在性探测 + pcall"）✓ |
| 它在你机器上跑起来了吗 | ✅ **跑起来了**（`活实例: UPI_WorldActor_C×1 UPI_Handler_C×1 UPI_UICore_C×1 SCML_WorldActor_C×1`），**没崩** |
| 我们能不能**调用**它的函数 | **函数对象找得到**（`StaticFindObject("<类路径>:<函数名>")` 对 13 个名字**全部返回真 UObject**）⇒ 难点不是"找得到"，而是**"参数怎么传"** —— SDK 给出了签名 ✓ 见下 |
| ★ **最大的门槛** | **它几乎所有 `UPI_*` 函数的第一个参数都是 `CallObject`** —— "**实现了接口 `UPI_InterfaceFunctions` 的（你自己 mod 的）回调对象**"。纯 Lua 造不出 UObject ⇒ **这是方案②的真正卡点**（不是函数名、也不是调用方式）|
| 有没有**不需要 CallObject** 的入口 | ✅ **有**: `SCML_FunctionLibrary`（`SCML_CPP_SendToUE4SSLog` / `SCML_CPP_GetFileContents` / `SCML_GetVersionNumberString` …）—— **纯参数、纯返回值**，是我们能直接调的；但它是**工具函数库，不含 UI/输入**（UI 与输入都在需要 CallObject 的 `UPI_*` 那侧）|
| 它自己有没有改键 UI | **没有**（ReadMe: rebinding 属"后续版本计划"）|

### 从 SDK 文档抄下来的**关键签名**（原文）

```
UPI_RegisterMod(CallObject:Object, ModName:String, ModCreator:String,
                RegisterMenu:Bool, EnterMenu:Name)
                -> Valid:Bool, ErrorOutput:Name
UPI_RegisterInput(CallObject:Object, InputName:Name, InputDesc:String, InputActive:Bool,
                  InputKey:Key, Shift:Bool, Control:Bool, Alt:Bool, InputState:Name,
                  ReportHold:Bool, TillHold:Float, HoldInterval:Float)
                -> Valid:Bool, Active:Bool, ErrorOutput:Name
UPI_SendNotif(CallObject:Object, Message:Text)
UPI_SetInputActive(CallObject, InputName, InputActive) -> Valid, ErrorOutput
UPI_EnterInputState(CallObject, EnterInputState:Name)  -> Valid, ErrorOutput
UPI_ExitInputState(CallObject, ExitInputState:Name)    -> Valid, ErrorOutput
UPI_OpenMenu(CallObject, Menu:Name, MenuTitle:String)
UPI_CloseMenu(CallObject) -> Valid, ErrorOutput
UPI_AddTextOption / UPI_AddEmptyOption / … (菜单盒子) + UPI_Update* / UPI_ResetMenu

回调（接口 UPI_InterfaceFunctions —— **要在你的 CallObject 上实现**）:
  UPI_Callback_KeyPressed(InputState:Name, InputName:Name, Key:Key, Shift/Control/Alt:Bool)
  UPI_Callback_KeyHold(...) / UPI_Callback_KeyReleased(...)
  UPI_Callback_MenuOpened(Menu:Name, FromMenu:Name, FromSameMod:Bool) / MenuClosed(...)
  UPI_Callback_UIHover(Menu, Callback, Index, MenuBox) / UPI_Callback_UI(Menu, Callback, Input, Index, MenuBox)
```
★ **注意**: `UPI_RegisterInput` 里有 `InputKey : {Key}` + `Shift/Control/Alt` —— 也就是说
**"改键"这件事在 API 层是现成的**（重新调一次、同名覆盖即可），而且**修饰键是它自己处理的**
（不受 UE4SS "按住修饰键也触发裸键"那个坑影响）—— 这是它最有价值的部分。

**⇒ 结论**: 方案②"游戏内 UI 改键"**技术上成立**（函数能拿到、能调；`SCML_CPP_SendToUE4SSLog` 已实测成功），
但**卡在 `CallObject`** —— 而且 2026-10-07 实测确认: **`CallObject` 不合格时它不是报错，而是崩游戏** ✗。
所以只有三条路:

1. **运行时创建它自己的"回调对象"**: pak 里有 `UPI_ModObject`（`FindAllOf("UPI_ModObject_C")` = 1，
   说明这个类在跑），用 UE4SS 的 `StaticConstructObject` 造一个实例当 `CallObject` —— **不用 pak、不用编辑器**。
   ⚠️ 但它是否实现接口、BP 构造是否有副作用，**都要实测**（下一步就试这个，且必须单独开关 + 黑匣子）。
2. **我们自己发一个几十 KB 的小 pak**（里面一个实现该接口的 BP 对象）当"桥" ——
   代价: 需要 UE5.1 编辑器 + 打包工具链（`UnrealPak`/`repak`）、不能复用它的示例资产、多一个安装步骤、
   引擎升级可能失效 ⇒ **本项目从没引入过的重依赖**。
3. **不用它的输入系统**，走替代路线（自建面板 / 控制台命令 / 只读面板 + `pwpr_keys.json`）；
   另有"临时 hook `PlayerController:InputKey` 捕获任意按键"这条自建思路（未验证）。

★ 另外**要拿的东西**: SDK 只有 **v0.01.09**（文档里 `UPI_RegisterMod` 是 5 参），
而装的是 **v0.01.10**（实测 **7 参**）⇒ **去 Nexus Files 页找有没有 v0.01.10 的 SDK**，
或者去作者 Discord 要 —— 有了新签名（7 个参数的类型/顺序）才能安全地调它。

---

## 二、阶段划分（**一步一步来，不跳步**）

### 阶段 A —— 只读探测（**已实现 v2**，`unipal_probe = true` 默认开）

> ⚠️ **v1 的检测是错的（2026-10-06 玩家两轮日志证明）**: 未安装 UniPalUI 时它仍然报
> `类: 5/5 找到` + `API: 13/13 找到`（`NumParms` 全是 `?`）⇒ `StaticFindObject("<类路径>")`
> **对不存在的路径也返回非 nil** ⇒ 那些"类"根本不是真对象。
> **唯一可靠的信号是 `FindAllOf`**（同两份日志里"活实例"从 `无` 变成 `…×4`，完全正确）。
> ⇒ **v2 改用**: ① 检测只看 `FindAllOf` 的活实例；② 函数靠
> `实例:GetClass()` → 沿 `Children/Next` 链**枚举真函数**（读 `GetName()` + `NumParms`）；
> ③ 调用只在活实例上按名字调（和我们对 `RequestBuild_ToServer` 的做法一致），不再猜函数路径。

* **做什么**: 启动后 **2.5 秒**、在**游戏线程**上（`Sched.game_thread`）只读地:
  1. 这些蓝图类在不在: `UPI_FunctionLibrary`（函数库，API 就在这儿）、`UPI_WorldActor`、
     `UPI_Handler`、`UPI_MenuGenBox`、`SCML_Core`；
  2. 世界里有没有它们的**活实例**（`FindAllOf("UPI_WorldActor_C")` 等）⇒ 判断"它真的在跑"；
  3. 13 个 API 函数（`UPI_RegisterMod` / `UPI_RegisterInput` / `UPI_SendNotif` / `UPI_OpenMenu` …）
     **存在吗**、**各几个参数**（读 `UFunction.NumParms`）。
* **风险**: 零（只 `StaticFindObject` / `FindAllOf` / 读属性，不调用任何东西）。
* **看哪里**: 日志里搜 **`UniPalUI 探针（阶段 A: 只读）`**；`F7` 里也有同样的几行。
  典型输出:
  ```
  ==== UniPalUI 探针（阶段 A: 只读）====
  UniPalUI 探针(阶段A): **检测到**
    类: 5/5 找到
    API: 13/13 找到 → UPI_RegisterMod(2) UPI_RegisterInput(3) UPI_SendNotif(2) …
    活实例: UPI_WorldActor_C×1
  ```
  （参数个数是**真值**，来自函数对象本身，不是我猜的。）

### 阶段 B —— 真的调一次 `UPI_SendNotif`（**已实现，默认关**）

* **怎么开**: `pwpr_config.json` 里 `"unipal_call_notif": true` → **重启游戏**。
* **会做什么**: 只在 ①阶段 A 找到了 `UPI_SendNotif` ②它的参数个数是 **1~2** 时，
  才按"1~2 个字符串"去调一次（文本 = `PWProjection 探针: 能收到吗？`）。
* **怎么判读**:
  * 屏幕上出现 **UniPalUI 的通知**（左上角）⇒ **调用链通** ⇒ 方案② 的地基有了 ✅；
  * 日志写 `阶段 B 调用 UPI_SendNotif: 失败 —— …`（且游戏没崩）⇒ 参数类型猜错了，
    需要换一种传法（下一步再试）；
  * **游戏崩了** ⇒ 说明"参数类型不对会崩" ⇒ 这条路要更小心（把开关关回去，改用"先找签名再调"的办法）。
* ⚠️ **风险**: 参数类型只能从个数猜，**可能崩**。所以默认关、且只在 1~2 个参数时尝试。

### 阶段 C —— 注册输入 + 收回调（**还没做，等 B 的结果**）

* 目标: `UPI_RegisterInput` 注册一个输入 → 玩家按它 → **我们收到回调** → 触发我们的动作。
* 卡点: 见上面那句"回调走蓝图接口"。三条绕法（①/②/③）都要**实测**。
* 如果 C 通了: 就能做"**游戏内改键面板**"（用它的菜单盒子: `Text`/`Toggle`/`Select`
  + 输入状态栈 + 同名重注册）⇒ 待办 5 的 ④ UI 改键 落地。

---

## 三、已知的坑（先记住，别重复踩）

1. **它的开菜单键是 `Shift+Y`** —— 和我们默认的 `key_capture = Y` **撞车**（UE4SS 按住修饰键
   也会触发裸键）⇒ 将来接入时要么把它当"冲突"交给它的冲突管理，要么把采集键改掉；
2. **它要求官方 UE4SS**（`experimental-latest`），而我们跑的是 **Okaetsu 那条分支** ⇒ 兼容性未实测；
3. **它自己承认有破坏性 API 变更**、且仍在早期开发（ReadMe: "MOD IN DEVELOPMENT"）
   ⇒ 我们**绝不能**把功能建立在它之上，只能"检测到就增强，没有就走配置文件"；
4. **不要打包它的任何文件**（只在自己这边探测 + 调用）；要不要在 README 里写"可选前置"
   由玩家决定；
5. 它有已知卡死情形（菜单可能卡住没鼠标、别的 mod 不管理输入状态会把它的输入锁住）
   ⇒ 真要接入，**进出输入状态必须成对**、异常要能退出。

---

## 四、这份探索怎么继续（下一步做什么）

> ★★ **2026-10-06 第四轮之后的最快路径**: 我们缺的核心信息是**它这套版本里 API 的真实函数名/签名**
> （那份 `Metadata.txt`）。三条路，按"成本/可行性"排:
>
> 1. **先看它自己的下载包里有没有 `Metadata.txt`** —— 玩家那份解压出来的目录里
>    **只有** `UniPalUI - ReadMe.md` / `UniPalUI - Changelog.md` / `(STEAM)` / `(XBOX)`；
>    但**压缩包（.7z）里可能还有**（解压时漏了？）⇒ 请玩家在 7-Zip 里打开看一眼，
>    或者到 Nexus 的 **Files 页 / 它的 Discord（The Broken Chatbox）** 要这份文档 —— 它 ReadMe 明确说
>    "**prefer lua 的 modder 看 Metadata.txt 里的函数清单**" ⇒ 这份文件就是为 Lua 用户准备的。
> 2. **v5 诊断的结果**（本页实测记录）: 如果"原始返回"里冒出了非 nil 的东西 ⇒ 说明名字其实对，
>    只是我之前的校验误杀 ⇒ 直接进阶段 B（`unipal_call_notif`）；
>    如果全是 `nil` ⇒ 名字确实不对 ⇒ 回到第 1 条拿真名。
> 3. 万一 **Metadata.txt 拿不到、名字也问不到** ⇒ 本方案就**到此为止**（结论写进本文档），
>    改走替代路线: ① **自建可点击面板**（我们已有造控件能力，难点是"输入焦点/不抢游戏输入"）；
>    ② **控制台命令入口**（`ConsoleCommandsMod` 那种，把低频动作做成命令、不占键）；
>    ③ **只读面板**（只显示按键表与状态，改键仍靠 `pwpr_keys.json`）。
>
> ★ 另外一条**完全绕开 UniPalUI** 的思路（记录备查，未验证）:
> "游戏内改键"最难的是**捕获"玩家按了哪个键"**（`RegisterKeyBindAsync` 只能绑已知键）。
> 可能的自建路径: **临时 hook `PlayerController:InputKey`** 之类"所有按键都会经过"的函数，
> 在"正在改键"的那几秒里读出按的是哪个键，改完立刻卸载 hook。
> 风险: 每键都进我们代码（性能 + 重入），必须先做小实验；**没实测前不当结论**。

1. **玩家**: 正常启动一次游戏（不用改任何配置）⇒ 把日志里 `UniPalUI 探针（阶段 A: 只读）`
   那一段（或 `F7` 那几行）发我；
2. **我**: 看阶段 A 的参数个数决定阶段 B 怎么调（若 `UPI_SendNotif` 参数个数不在 1~2，
   先改探针的调用方式，再让玩家打开 `unipal_call_notif`）；
3. 阶段 B 有结论后，再谈阶段 C（回调）—— 那一步决定"游戏内改键面板"能不能做。

> ★ 约定（玩家 2026-10-06）: **成不成都会写进这份文档** —— 所以每次实测完，
> 把结论补到下面的「实测记录」一节。

---

## 五、实测记录

| 日期 | 构建 | 做了什么 | 结果 |
|---|---|---|---|
| 2026-10-06 | `2026-10-06.64` | **未装** UniPalUI，跑阶段 A v1 | 期望"没检测到"，实际报 `检测到` + `类 5/5` + `API 13/13`（`NumParms=?`）⇒ **v1 的类/API 检测是假阳性**（`StaticFindObject` 不可靠）。**活实例: 无** ✓（这条是对的）|
| 2026-10-06 | `2026-10-06.64` | **装上** UniPalUI（拷进 `Mods\NativeMods\UE4SS\Mods\UniPalUI\` + `Pal\Content\Paks\LogicMods\UniPalUI.pak`）再跑 | ★★ **活实例: `UPI_WorldActor_C×1 UPI_Handler_C×1 UPI_UICore_C×1 SCML_WorldActor_C×1`** ⇒ **它的 DLL + pak 在我们这条 UE4SS 分支上真的加载并在跑了，而且没崩** ⇒ 方案② 的地基看起来是通的 ✓<br>（类/API 那两行仍沿用 v1 的假阳性，无参考价值）|
| 2026-10-06 | `2026-10-06.65` | 阶段 A **v2**（活实例 + `Children/Next` 枚举真函数与参数个数）| 检测**对了**（`活实例: …×4`），但 **`函数枚举: 4 个类 / 0 个函数`** ⇒ UE5 里 `UStruct.Children` 是**非反射**的 FField/UField 指针，UE4SS 属性访问**读不到**（`cls.Children` → nil）⇒ 这条路作废 |
| 2026-10-06 | `2026-10-06.66` | 阶段 A **v3**: 三种手段同时试 + **严格校验**（拒 TrivialObject: ①非 nil ②`tostring` 不含 `TrivialObject` ③`NumParms` 读得出 ④`GetFullName` 含函数名），并统计各手段命中数 | **三手段全 0**（`StaticFindObject=0 · 活实例成员=0 · Children链=0`）⇒ 从 Lua 侧**按名字够不到**它那 13 个 API ⇒ **强烈怀疑名字不对**（我们那份清单来自页面上的 **0.1DEV**，而装的是 **V0.01.10 TEST**，它的 Changelog 自己写过改名/破坏性变更）|
| 2026-10-06 | `2026-10-06.67` | 阶段 A **v4**: ① **扫 Lua 全局**（`_G`）；② 打印每个活实例的**真实类全名**；③ 保留三手段统计 | ★ **Lua 全局: 0 个** ⇒ 它的 DLL **没有**把 API 注册进 Lua（`on_lua_start` 不等于"注册了 Lua 函数"）⇒ Lua 侧只能走**蓝图函数库**（名字要来自它那份 `Metadata.txt`，我们**没有**这个文件）。<br>★ **真实类路径拿到了**（有价值）: `UPI_WorldActor_C=/Game/Mods/UniPalUI/UPI_WorldActor.UPI_WorldActor_C`、`UPI_Handler_C=…/UPI_Handler.UPI_Handler_C`、`UPI_UICore_C=…/UPI_UICore.UPI_UICore_C`、**`SCML_WorldActor_C=/Game/Mods/SCML/SCML_WorldActor.SCML_WorldActor_C`**（SCML 在**另一个目录**，我原来猜错了）。<br>★ 三手段仍全 0 |
| 2026-10-06 | `2026-10-06.68` | 阶段 A **v5**: **发现 v3/v4 的校验条件本身写错了** —— 我要求"`NumParms` 读得出来"才算真函数，但 **`UFunction.NumParms` 不是反射属性**（没有 `UPROPERTY`）⇒ UE4SS 按名字读不到 ⇒ **真函数也被判成假** ⇒ "三手段全 0"**不能证明名字不对**。<br>⇒ v5: 去掉 `NumParms` 这个必要条件，并**把原始返回值报出来**（`type` + `tostring` 前 70 字）| ★★ **决定性结果**: `原始返回(StaticFindObject): 非 nil 13 / nil 0` ⇒ **13 个函数对象全都找得到**
（`UPI_RegisterMod→userdata=UObject: 0x…` … 13 个地址各不相同）⇒ **"名字不对"这个假设被推翻**，
真正的问题是"**怎么调、签名是什么**" ✓<br>★ 同一天玩家找到 **`UPI_SDK`**，签名问题就此解决（见上面"结论先行"）|
| 2026-10-06 | `2026-10-06.69` | 阶段 B **重写成"三步真调"**（依据 SDK 签名）: ① `SCML_CPP_SendToUE4SSLog(msg)`；② `UPI_RegisterMod(<候选CallObject>, …)` 读 `Valid`/`ErrorOutput`；③ 注册成功才 `UPI_SendNotif` | ⚠️ **全失败，但信息不足**: `① SCML 函数库调用: 失败（三条路径都没调通）` + `② Valid=nil ErrorOutput=nil`（四个候选都是）—— **因为我把 `pcall` 的错误原文吞了**、返回值的个数/类型也没记 ⇒ 无法区分"路径错 / 方法不存在 / 这种调用方式不被支持 / 参数不对"。**这是我的探针设计缺陷** |
| 2026-10-06 | `2026-10-06.70` | 阶段 B **v7: 把错误说出来**（方法是否存在 + `pcall` 错误原文 + 返回值个数/类型）| ★★★ **突破，三件事一次问清**:<br>① `SCML_FunctionLibrary.CDO` 的成员读到的是 **`userdata=UFunction: 0x…`** ⇒ **方法真的拿得到、而且是真 UFunction**（前几轮"member=0"纯粹是我的校验写错）；<br>② 调用报的是 **`[UFunction::setup_metamethods -> __call] UFunction expected 2 parameters, received 1`** ⇒ **这句错误本身给出了真实参数个数**，而且**校验发生在执行之前**（没跑进原生代码）⇒ **"故意少传" = 零副作用地问参数个数**；<br>③ 四个**世界 actor** 的 `UPI_RegisterMod` 成员都是 **TrivialObject** ⇒ **API 不在世界 actor 上，而在函数库 CDO 上**（我②的候选对象选错了）。|
| 2026-10-06 | `2026-10-06.71` | 阶段 B **v8**: 解析函数库 **CDO**；用 `probe_arity`（故意 0 参 → 读错误里的 `expected N`）问参数个数；按问出来的个数真调 `SCML_CPP_SendToUE4SSLog`；用正确个数调 `UPI_RegisterMod` | ★ **两条报错都很有价值**:<br>① `SCML_CPP_SendToUE4SSLog(...)` 报 **`[push_objectproperty] Error: Value must be UObject or …`** ⇒ **这次调用真的进到了 UE4SS 的参数编组器**（⇒ 函数存在、可调），**只是参数类型不对**：这个版本它有**一个参数必须是 UObject**（SDK 0.01.09 文档写的是 1 个字符串）⇒ **我按旧文档补的参数是错的**；<br>② `UPI_RegisterMod(...)` 报 `Tried calling a member function but …` ⇒ **`UPI_*` 在函数库 CDO 上读不到成员**（`②` 13 个全是 `?`），而 `StaticFindObject` 拿回的那 13 个打印是 **`UObject:`（不是 `UFunction:`）** ⇒ **那批不是可直接调的函数对象**；<br>③ `SCML_CPP_SendToUE4SSLog(2)` ⇒ **SCML 侧的参数个数问出来了（2）** ⇒ `SCML_*` 是"拿得到、调得动"的。|
| 2026-10-06 | `2026-10-06.72` | 阶段 B **v9**: 成员矩阵打在 **5 个对象**（UPI/SCML 的 CDO + 类对象 + `SCML_UI_Core.C`）；SCML 写日志函数按**两种参数顺序**试调 | ★★★ **决定性突破**: `③ SCML write-log (string, UObject) (on SCML_Lib.C): **OK**` ⇒ **纯 Lua 确实能调用它的蓝图函数库**（真签名 = 2 个参数、顺序 `(字符串, UObject)`）！<br>❌ 同时: `② UPI_Lib.CDO / UPI_Lib.C: 真 UFunction **0** 个`，且 `① UPI_FunctionLibrary.C → userdata=**UObject**`（SCML 那边是 `UClass`）⇒ **我给的 UPI 路径根本没指到类** ⇒ 那 13 个函数**不在 `UPI_FunctionLibrary` 上**。|
| 2026-10-07 | `2026-10-06.73` | 阶段 B **v10**: 改**从类名入手**（`FindAllOf`）逐个查 11 个候选类，对每个类的实例与类对象读 13 个 `UPI_*` + `SCML_CPP_SendToUE4SSLog` | ❌ **游戏崩了**（`EXCEPTION_ACCESS_VIOLATION reading 0x70`，调用栈 30 层全在 UE4SS；UE4SS 日志最后一行正是阶段 A 的头部）。<br>★ **根因（我的设计错误）**: v10 把"逐成员问参数个数"放进了**声称只读的阶段 A**，而问的办法是**故意 0 参调它** —— 对 **0 参函数**（SDK 里 `UPI_ExitMenu` / `UPI_ForceBack`）**那就是真的执行**，宿主还可能是 **CDO/类对象** ⇒ 空指针解引用 ✓。详见 `docs\踩坑记录.md` **§72** |
| 2026-10-07 | `2026-10-07.74` | **v11 修复**: ① 阶段 A **绝对不调用任何函数**；② 参数个数一律查 **`Unipal.ARITY`**（SDK 文档值）—— **查不到的不调**，**0 参的一律不调**（`Unipal.NO_CALL`）；③ 只把**活实例**当调用宿主（CDO/类只读成员）；④ 阶段 A/阶段 B **每一步都写 `Log.solid` 同步黑匣子** | ✅ **没再崩** ✓<br>★★★ **找到 API 的真正宿主了**: `① UniPalUI_C: FindAllOf=1, 成员: **13个** → UPI_RegisterMod(5) UPI_RegisterInput(12) UPI_SetInputActive(3) UPI_EnterInputState(2) UPI_ExitInputState(2) UPI_SendNotif(2) UPI_OpenMenu(3) UPI_CloseMenu(1) UPI_AddMenuOption(3) UPI_UpdateMenuOption(3) UPI_UpdateDescBox(3) UPI_ResetMenu(1) UPI_ExitMenu(?)【0参·禁调】` ⇒ **13 个 `UPI_*` 全都在 `UniPalUI` 这个 Actor 类上**（SDK 标题「The main UniPalUI Actor」完全对上），而且**活实例与类对象上都能读到真 `UFunction`** ✓✓<br>★ 同时确认: `UPI_ModObject_C` / `SCML_UI_ModObject_C` 等**都是 0 个 UPI 成员**（它们是"回调对象/UI"类，不是 API 宿主）；函数库（`SCML_FunctionLibrary_C`）`FindAllOf` 查到 0（**函数库没有实例**，只能靠 `StaticFindObject` 拿）⇒ 以后两种手段都要用。<br>★ `③ UPI_RegisterMod on UniPalUI_C[1] (5 参): FAIL`，报错被截断成 `[UFunction::setup_metamethods -> __call] UFun…` ⇒ 是**参数个数/类型不符** ⇒ 而且**没崩** ⇒ 实证"个数不符时 UE4SS 在执行前就报错" ✓ |
| 2026-10-07 | `2026-10-07.75` | **v12**: 宿主改用 `UniPalUI` 活实例；"先用文档值试 → 从 `expected N` 读真实个数 → 用真实个数重试" | ❌ **又崩了一次**，但**黑匣子把位置钉死了**: 最后两行是<br>`[unipal] 阶段B: 调 UPI_RegisterMod（文档值 5 参，宿主=UniPalUI_C[1]）`<br>`[unipal] 阶段B: 参数个数不符（真实 7），按真实个数重试` ⇒ **崩在"用真实个数 7 重试"那一次**。<br>★ **两条硬结论**: ① `UPI_RegisterMod` 的真实参数个数是 **7**（SDK v0.01.09 文档写 5 —— 装的是 v0.01.10，签名变了）；② **`CallObject` 不合格时它不会优雅报错，而是空指针崩溃**（转储: `reading 0x70`，UE4SS + 游戏侧 40 帧）⇒ **这就是"必须实现 `UPI_InterfaceFunctions`"那道门的实证** ✗ |
| 2026-10-07 | `2026-10-07.76` | **v13 隔离**: 新增**独立开关** `unipal_try_register`（默认 false）管住这唯一的高危调用；并加**守卫** —— 只有"像 mod 回调对象"的类（类名含 `ModObject`，例 `UPI_ModObject_C`）的**实例**才能当 `CallObject`。`unipal_call_notif` 保留做**安全**的那部分 | ✅ **实测没崩**（`③ UPI_RegisterMod: **跳过**（配置 unipal_try_register=false …）`）⇒ 守卫按设计工作；同时确认 `UPI_ModObject_C: FindAllOf=1`（**这个类在跑**，有实例）⇒ 路① 有戏 |
| 2026-10-07 | `2026-10-07.77` | **路①（玩家选定）** 实装: 开关 `unipal_create_modobject` —— `StaticConstructObject(UPI_ModObject_C 的类, Outer=UniPalUI 活实例)` 造自己的 `CallObject` | ✅ **第一步实测成功**: `[unipal] 路①: 新建成功 userdata=UObject: 0x…` ⇒ **运行时能造出"实现了接口的对象"，不用 pak、不用编辑器** ✓✓<br>❌ 第二步（开 `unipal_try_register`）**又崩了**，黑匣子指向: `阶段B: 调 UPI_RegisterMod（文档值 5 参, CallObject=**UPI_ModObject_C[1]**）` → `参数个数不符（真实 7），按真实个数重试` → 崩。<br>★ **发现我的 bug**: 日志里 `CallObject=UPI_ModObject_C[1]` 是**扫描到的那一个**（= UniPalUI 自己的 mod 对象），**不是我们新建的** ✗ —— 新建成功后又被后面的扫描循环覆盖了 ⇒ 等于"拿它自己的注册对象再注册一次"，崩得合理。 |
| 2026-10-07 | `2026-10-07.87` | **v21**: 出参**按名字读**（和 `NewObject` 一样，`Valid`/`ErrorOutput` 也是命名字段）| ★★★ **墙破了**: `路①b: SCML_CPP_NewObject 成功（Outer,Class,{}）出参表{**NewObject=userdata=UObject: 0x…**}`<br>⇒ **作者自己的代理接口能造出对象**，而且**输出是通过出参表的"命名字段"返回的**（`out.NewObject`，不是 `out[1]`）✓✓<br>⇒ 我们现在有一个**由作者 API 正规创建、并经 C++ 侧初始化的 `ModObject`** ⇒ 这正是 `UPI_RegisterMod` 需要的东西 ✓<br>⏳ 下一步: 用它去注册（配置 `unipal_try_register: true`，`unipal_allow_static_callobj` 保持 false —— 对象来自 `scml` 路径，守卫会放行）|

> ★★ **拿到的正确调用姿势（2026-10-07 定稿）**:
> ```lua
> local out = {}
> m(scmlActor, Outer, Class, out)      -- 出参必须传表；结果是 out.NewObject
> ```
> ```lua
> local v, e = {}, {}
> f.fn(unipalActor, callObj, "PWProjection", "CitrusDR", true, "", v, e)  -- 5 输入 + 2 出参表 = 7 槽
> -- 结果读 v.Valid / e.ErrorOutput（**按名字**，别按 [1]）
> ```
（完整报错给的答案） | ★★★ **决定性发现**: 把错误原文放开到 400 字后，`SCML_CPP_NewObject` 的报错是<br>`Tried storing reference to a Lua table for an 'Out' parameter when calling a UFunction but no table was on the stack`<br>⇒ **UE4SS 调用含"输出参数"的 BP 函数时，每个出参都要传一个 Lua 表来接收**（不是 `nil`）。<br>★★ 这一条**同时解释了三次崩溃**: 输出槽给 `nil` ⇒ 引擎往空指针写 ⇒ `EXCEPTION_ACCESS_VIOLATION reading 0x70` ✓✓<br>⇒ 正确写法: `SCML_CPP_NewObject(Outer, Class, {})`（3 槽）；`UPI_RegisterMod(callObj, "PWProjection", "CitrusDR", true, "", {}, {})`（**5 输入 + 2 个出参表 = 7 槽**）；`UPI_SendNotif`（无出参）= 3 槽 ✓<br>⏳ 等下一轮日志 `③b 出参表: Valid表[1]=… ErrorOutput表[1]=…` |

> ★★★ **UE4SS 调用约定（2026-10-07 用崩溃换来的，务必记住）**:
> 1. **参数个数 = 输入 + 输出**（`UFunction expected N parameters` 里的 N 算了出参）；
> 2. **每个输出参数必须传一个 Lua 表**（引擎把出参写进那个表）—— 传 `nil` **不是报错而是崩游戏**
>    （`reading 0x70`，调用栈全在 UE4SS）；
> 3. 少传/多传参数**是安全的**（UE4SS 在执行前就报错）⇒ "故意传错个数问签名"这个技巧成立；
> 4. 只有"**个数对、类型对、出参给了表**"时函数才会真正执行 —— 那时就要小心宿主对象是否正确。
（1 输入 / `Outer,Class` / `Outer,Class,nil` / `Class,Outer` / `Class,Outer,nil` / 在**类对象**上调）—— 顺序、个数、宿主全覆盖；② 新增开关 `unipal_allow_static_callobj`（默认 false）: **C++ 侧起来之后**值得再试一次"用生造对象注册" | ✅ **玩家反馈: `Register Timeout` 消失了** ⇒ **C++ 侧注册成功** ✓✓（安装位置已摆正）<br>❌ 但 `SCML_CPP_NewObject` 三种形态全失败:<br>· `Outer,Class`（2 输入）⇒ `[UFunction::setup_metamethods -> __call] …`（**参数个数不符** ⇒ 它要 3 个）<br>· `Outer,Class,nil` / `Outer,Class,false`（3 个）⇒ `Tried storing reference to a Lua table for an …`<br>⇒ 顺序/个数/宿主都还没对准（v19 的矩阵就是为这个铺的）|
 ★★★ **玩家在 `UE4SS.log` 里找到决定性一行**:<br>`[Lua] [SCML] SCML_WorldActor : Register Timeout, Some C++ functions may not be available`<br>⇒ **UniPalUI 的 C++ 侧根本没注册成功**，与"它的 `dlls\main.dll` 装在了**惰性**的 UE4SS 树（`Pal\Binaries\Win64\ue4ss\Mods\`）里"**完全对上** ✓✓<br>⇒ 这解释了 `SCML_CPP_NewObject` 的怪错（`Tried storing reference to a Lua table…`）: **C++ 实现不在**，那批 `SCML_CPP_*` 是残缺的。<br>★ **下一步（用户操作，2 分钟）**: 把 `Pal\Binaries\Win64\ue4ss\Mods\UniPalUI\` **整个复制到** `Mods\NativeMods\UE4SS\Mods\UniPalUI\`（与 `PWProjection` 并列）⇒ 重启，**确认 `Register Timeout` 那行消失** |

> ★★ **安装位置检查清单（2026-10-07 加入）**：
> 1. pak（BP 部分）: `Pal\Content\Paks\LogicMods\UniPalUI.pak` ✓ **装对了**
> 2. mod 文件夹（DLL/C++ 部分）: 必须是**当前活跃的 UE4SS 树**下的 `Mods\UniPalUI\`
>    （本机活跃树 = `Mods\NativeMods\UE4SS\`，判据: 我们的 mod、其它 11 个 mod、`UE4SS.log` 都在那儿）
>    —— 玩家当前装在了 `Pal\Binaries\Win64\ue4ss\Mods\UniPalUI\`（**惰性树**）✗
> 3. 判据（**看日志，不要猜**）: UE4SS 日志里出现
>    `[Lua] [SCML] SCML_WorldActor : Register Timeout, Some C++ functions may not be available`
>    ⇒ **C++ 侧没起来**；这行消失才算装好 ✓
（缓冲日志在崩溃时会丢）；② ★★ **新规则: 只允许用"作者代理造出来的对象"（`SCML_CPP_NewObject`）去注册** —— 直接 `StaticConstructObject` 生造的对象**实测会崩** ⇒ 这不是"怕崩就屏蔽"，而是**只用作者支持的那条构造路径** | ⏳ 等下一轮（**只开创建**，先确认作者代理能不能造出对象、并看它的黑匣子结果）|

> ★★★ **第三次崩溃（`.80`，2026-10-07）的结论 —— 签名对了，问题在"对象"**:
> 黑匣子最后一行是 `阶段B: 调 UPI_RegisterMod（实测签名(5 输入+2 输出) → 7 参, CallObject=新建的 UPI_ModObject_C(2 参)）`
> ⇒ 参数个数/顺序**这次是对的**（dump 实测），所以崩的原因**只能是传进去的那个对象**:
> `StaticConstructObject` 只做了"分配 + 复制默认值"，**没有走它自己的初始化** ⇒ 它的 BP 代码
> 读这个对象上的字段/注册表时拿到空指针（`reading 0x70`）✗
> ⇒ 作者专门提供 `SCML_CPP_NewObject`（"returning an object of the given class"）应该就是给这个用的
> ⇒ **下一步只用它造对象，再去注册**（且两步分开跑，避免一次崩溃把两边信息都丢掉）。
 —— `UPI_RegisterMod(callObject, ModName, ModCreator, RegisterMenu, EnterPage, Valid, ErrorOutput)` = **5 输入 + 2 输出槽(nil) = 7**；顺带修 `SCML_CPP_NewObject` 的参数顺序（**`(Outer, Class)`**，我原来传反了）；注册调用没抛错就顺手发一条 `UPI_SendNotif(callObject, Message:Text, CallerName)`（**3 参、无未知参数**）⇒ 屏幕上出现通知 = 调用链真正通 | ⏳ 等下一轮日志（`unipal_call_notif: true` + `unipal_create_modobject: true` + **`unipal_try_register: true`**）|

> ★★★ **2026-10-07 突破: 玩家用 UE4SS 控制台的 dumpers 导出了 `UE4SS_ObjectDump.txt`**
> （"Generate BP SDK"），里面有**每个 `UFunction` 的真实参数表**（类型 + 内存偏移）——
> **这才是权威来源**，比 SDK 文档可靠：
> * **读法**: 属性行里的 `[o: N]` 是内存偏移，**按偏移排序 = 参数顺序**；
> * ★★ **UE4SS 的"参数个数"把输出参数也算进去** ⇒ 调用时必须**连输出槽一起传（给 `nil`）**
>   —— 这解释了 `UPI_RegisterMod` 为什么报 "expected **7**"（文档只列 5 个输入）✓
> * 实测签名（节选）:
>   ```
>   UPI_RegisterMod  : callObject:Object, ModName:Str, ModCreator:Str, RegisterMenu:Bool,
>                      EnterPage:Name | Valid:Bool, ErrorOutput:Name            → 7
>   UPI_SendNotif    : callObject:Object, Message:Text, CallerName:Str          → 3（无输出、无未知）
>   UPI_RegisterInput: callObject, InputName:Name, InputDesc:Str, InputActive:Bool,
>                      InputKey:Key(结构), Shift, Control, Alt, InputState:Name,
>                      TillHold:Double, HoldInterval:Double | Valid, Active, ErrorOutput → 14
>   SCML_CPP_NewObject: Outer:Object, Class:Class | NewObject:Object            → 3（**顺序是 Outer,Class**）
>   ```
> * ⚠️ 同 dump 里那些 `CallFunc_*` / `KeyData` / `ModObject` 是 **BP 局部变量**，不是参数 ⇒ 别算进去。
> * ★ 方法论: **以后要调任何第三方 BP 函数，先 dump 出签名，再写调用** —— 别再靠文档/猜测。

> ★★ **2026-10-07 关键发现（安装位置）**: 全游戏目录搜索显示 UniPalUI 装在
> **`Pal\Binaries\Win64\ue4ss\Mods\UniPalUI`**（压缩包 `(STEAM)` 的原始布局），
> 而**真正在跑的 UE4SS 树是 `Mods\NativeMods\UE4SS\`**（我们的 mod、其它 11 个 mod、日志都在那儿）
> ⇒ `Win64\ue4ss\` 那棵树是**惰性的** ⇒ **UniPalUI 的 `dlls\main.dll`（C++ / SCML C++ 侧）很可能没被加载** ✗。
> 它的 changelog 明确说菜单里有"**SCML C++ 侧是否活跃**"的状态指示，而 `SCML_CPP_*` 就是 C++ 实现的那批
> （我们调的可能是蓝图回退版）。
> ⇒ **建议把 `UniPalUI` 那个 mod 文件夹（含 `dlls\main.dll` + `enabled.txt`）挪到
> `Mods\NativeMods\UE4SS\Mods\` 下**（与 `PWProjection` 并列），再重启验证 —— 可能改变
> `SCML_CPP_NewObject` 等函数的行为，也可能让 API 与文档一致。

### 下一步（三条都写清代价，等玩家定）

1. **拿真签名**（推荐先做，最省事）: 去作者 Discord / Nexus 评论问 `UPI_RegisterMod` 在 **v0.01.10** 的
   7 个参数（类型 + 顺序）；拿到后直接写进配置 `unipal_register_args`（**不用改代码**）✓
2. **把 UniPalUI 的 DLL 部分挪到正确的 UE4SS 树**（见上面的发现）—— 可能一次解决多个问题 ✓
3. 若上面两条都走不通: **路②**（自带几十 KB 桥 pak，需 UE5.1 编辑器）或 **路③**
   （不用它的输入系统: 自建面板 / 控制台命令 / 只读面板 + `pwpr_keys.json`）

> ★ **从 changelog 挖到的两条关键线索（2026-10-07）**:
> * **`SCML_CPP_NewObject`** 是作者提供的"造对象"接口（在 `SCML_WorldActor` 上）⇒ 比直接
>   `StaticConstructObject` 更"官方"，可能替我们做了必要初始化（**那正是"注册时崩"的可疑原因**）。
> * **`UPI_GetUniPalUI` 在 v0.01.10 新增了强制的 `WorldContext` 输入** ⇒ 说明 v0.01.10 确实往 API 里
>   塞了**对象类参数** —— `UPI_RegisterMod` 从 5 参涨到 7 参，很可能就是这类（**但顺序/类型仍未知**）。
> * 同 changelog: "**Removed `UPI_AddMenuOption` / `UPI_UpdateMenuOption`**" ⇒ 提醒: 我们打印的 `(N)`
>   是 **SDK 文档值、不是实测值**（`RegisterMod` 就是文档 5 / 实测 7）⇒ 别再把文档值当签名。

> ★ **SDK 版本情况（玩家 2026-10-07 核实）**: Nexus 上**只有 v0.01.09 的 SDK**（文档里 `UPI_RegisterMod` 是 5 参）
> + v0.01.10 TEST 的本体；历史版本页里没有可下载文件 ⇒ **拿不到 v0.01.10 的签名文档**，
> 所以那 7 个参数的类型/顺序只能靠"试探 + 观察返回值"（试探的安全性依据见上: 个数/类型不符 → 报错不执行；
> 只有"参数正好 + `CallObject` 合格"才会真的执行）。

> ★ **线索（2026-10-06）**: 读你游戏里的 `LogicMods\UniPalUI.pak` 资产清单确认:
> `/Game/Mods/UniPalUI/` 下确实有 `UniPalUI`、`UPI_FunctionLibrary`、`UPI_ModObject`、
> `UPI_InterfaceFunctions` …；而 **SDK 文档里那组 `UPI_*` 是挂在「## UniPalUI —— The main
> UniPalUI Actor」标题下的** ⇒ 它们应该在 **`UniPalUI` 这个 Actor 类**上，
> 而不是我一直在试的 `UPI_FunctionLibrary` ✓（v10 正在验证这一点）。

> ★ **v1 → v2 → v3 → v4 的教训（一句话）**: 在这个引擎上"证明某个对象/函数存在"**不能只靠 `~= nil`**
> —— `StaticFindObject` 对不存在的路径返回假对象（TrivialObject，truthy），`Children` 链读不到，
> 而**第三方文档里的 API 名字可能和你装的版本对不上**（0.1DEV vs 0.01.10 TEST）
> ⇒ 必须**多重校验 + 多手段交叉验证 + 从"能枚举的地方"取真名**，而且**只有实机日志才算数**。

### 顺带验证到的东西（同一份日志里）

* ✅ **按键可配置 + 单独文件全部生效**: `resnap=G`、`mode=F10`（`实际绑定成功 27 个，失败 0`）——
  `.63` 那个"生成的 JSON 少逗号 ⇒ 改键静默失效"的 bug 确认修好；
* ✅ **`F9/F10` 合并生效**（现在只有 `key_mode` 一个键）；
* ✅ **中文文件名可读**（`文件名编码: 已切到 .UTF-8` + `中文文件名: 1 个（可读 1，打不开 0）`）——
  `locale_utf8` 这条路在你的机器上**确实有效**；
* ⚠️ 发现两处"提示文本没跟着改键走"（小键盘行的 `= 主键 H/U`、方向键行的"别名 F10"）
  ⇒ `.65` 已改成动态取值（`Notify.KEYS` 的 `same_as` 字段）。
