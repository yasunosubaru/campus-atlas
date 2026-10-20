# 参与贡献 / Contributing

先读这一页，再提 PR。五分钟能省掉一轮来回。

## 上手

```bash
git clone https://github.com/yasunosubaru/campus-atlas.git
cd campus-atlas
flutter pub get
flutter test          # 770 tests
flutter run -d windows
```

环境要求：Flutter ≥ 3.24（Dart ≥ 3.5）。本仓库在 Flutter 3.47.7 / Dart 3.13.5 上验证。
Windows 上还需要 **WebView2 Runtime**（Win11 自带）。

## 工作流

1. 建自己的分支，不直接推 `main`
2. 提交时逐个列路径（不要 `git add -A`）
3. 推送分支
4. 发 PR

```bash
git checkout -b fix/whatever-it-is
git commit -m 'fix: 做了什么'
git push origin fix/whatever-it-is
```

## 提交前的自检

```bash
dart format --output=none --set-exit-if-changed lib test   # 格式
flutter analyze --fatal-infos                              # 0 issues
flutter test                                                # 全绿
python tools/check_desensitization.py                       # 脱敏守卫
```

四项都过再推。CI 会跑同样四项，其中脱敏守卫**失败即红**。

## 这个仓库的几条纪律

### 一、不代解验证

教务的课表与成绩查询挂着一个滑块挑战，CAS 还会追加二次认证。应用把页面原样开在
**应用内浏览器**里，由**本人**完成，应用只读**页面已经画出来**的内容。

- 不要写"自动过滑块"的功能，那既做不到也不该做。
- 不要为了跑通而把挑战的答案硬编码进去。
- 如果一个功能需要页面级验证，就让它需要。

### 二、没有契约就不猜

研究生课表、Ham 的写入接口、评教表单——这三样没有拿到契约，所以界面上标为不可用。

- 不要为它们编一个"看起来能用"的界面。
- 不要把猜测的字段名写进解析器。
- 拿到契约之后，在 `docs/` 里记下证据来源，再实现。

### 三、脱敏

这个仓库是公开的。个人姓名、学号、电话、邮箱、令牌都不进仓库。

- 截图用**合成数据**（`scripts/e2e/capture_screens.py` 抓的是演示数据集）。
- 测试里的学号用 `STUDENT-0000` 这种一眼假的占位符。
- 抓下来的页面（`test/fixtures/`）里那个学号必须保持 `REDACTED-ID`。
- `tools/check_desensitization.py` 是**绊线不是证明**：它给过假的"0 命中"，
  真正靠的是人眼过一遍 diff。

### 四、失败要能说清是哪种失败

校园后端的失败方式很杂（会话过期、门户页用 HTML 冒充 JSON、维护窗口）。
所以用 `Result<T>` 而不是异常，失败要带**种类**——UI 靠种类决定是"给个重试"
还是"请重新登录"。新增一种失败，记得同时加测试。

### 五、界面说人话

- 不要在界面上写"预期路径""待验证"这类给作者看的话，除非那确实是当前状态
  （评教页的那张路径表就是当前状态，它诚实地标了哪一步验过、哪一步没验过）。
- 不要在界面上承诺应用做不到的事。
- 中英双语都要改：`lib/core/i18n/app_localizations.dart` 是手写表，
  缺 key 由测试兜底。

## 提交信息

用祈使句，标题一行说清做了什么，正文说清为什么。

```
feat(timetable): 课表导入支持教务的滑块验证后的页面读取
fix(eval): /loginSSO 相对 forwardURL 按站点 origin 解析
docs: 记录 N2151 端点改为页面级验证
```

## 许可

提交即表示你同意你的贡献以 **MIT** 协议发布。你也确认贡献的代码是你自己写的，
或者你有权以 MIT 发布它。
