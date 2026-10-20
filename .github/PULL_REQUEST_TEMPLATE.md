## 这个 PR 做了什么 / What this PR does

<!-- 一两行说清 -->

Closes #

## 为什么 / Why

<!-- 动机、背景、关联的 issue -->

## 怎么验证的 / How it was verified

- [ ] `dart format --output=none --set-exit-if-changed lib test`
- [ ] `flutter analyze --fatal-infos`
- [ ] `flutter test`
- [ ] `python tools/check_desensitization.py`
- [ ] 实况跑过（说明跑的哪条链、看到了什么）

## 截图 / Screenshots

<!-- UI 改动请附图。**遮住学号、姓名、成绩**；
     演示截图请用合成数据（scripts/e2e/capture_screens.py 抓的那套）。 -->

## 纪律自检 / Discipline check

- [ ] 没有代解任何验证，也没有硬编码挑战答案
- [ ] 没有猜测缺失的接口契约
- [ ] 没有引入真实学号 / 姓名 / 分数 / 令牌
- [ ] 中英双语文案都改了
- [ ] 新增的失败种类有对应的测试
