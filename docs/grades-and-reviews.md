# 给分与评价 — 两套原版服务如何实现，以及数据在哪

这份文件回答三个问题，并且把**观察**、**推断**和**未决**分开写：

1. Luotopia 的「给分与评价」功能，真实服务是怎么实现的？
2. 它为什么在界面上没有数据？
3. **ham 生态里同样的功能是什么样子的？**（见 §4 —— 它存在，而且有服务端）

结论先写，分两套：

- **Luotopia 那套**：功能完整实现（`/api/v1/course/grades/*`，可按教师收窄），
  但公开可见的数据是空的 —— 2368 门课里 `review_count > 0` 的为 0。
- **ham 那套**：功能同样存在，服务端是 `ham-gateway` + `open-api.ham.nowcent.cn`，
  对外暴露为 MCP 服务 `https://mcp.ham.nowcent.cn/mcp`，**需要 Ham 账户授权才能读**。

⚠️ 本文件曾有一处错误结论 ——「ham 没有这个功能」。错因是只读了一个客户端仓库。
已在 §4 更正，并按本项目的规矩保留这个记录，没有悄悄改掉。

---

## 1. 它是什么

[V] 原版的功能族，从 `data/app.so`（Flutter Dart AOT 快照）的字符串里读出：

```
course_review.search            按名称/代码/关键词检索课程库 → courseUid
course_review.grades_by_name    同上，按课程名
course_review.teachers          某门课有成绩数据的教师与教学班
course_review.list_teachers     同上
course_review.grade_view        合并后的给分分布（可收窄到某个教学班或教师）
course_review.grade_stats       评价统计
course_review.reviews           公开评价正文
course_review.list_reviews      同上
course_review.submit_grade      用户提交自己的成绩
course_review.create_review     撰写评价
course_review.update_review     修改评价
course_review.delete_review     删除评价
course_review.my_reviews        我写的评价
course_review.list_mine         同上
course_review.my_eligibility    我是否有资格评某门课
course_review.sync_eligibility  同步资格
course_review.eligibility_sync  同上
```

三段 [V] 原文（应用自带的工具说明，逐字引用，不是我的转述）：

> **Searches the Luotopia course database by name, code or keyword and returns
> each match with its `courseUid` (the handle used by the other course_review
> tools), name, credits, community average rating and review count.**
> — `course_review.search@1`

> **Lists the teachers and teaching teams that have grade data for one course.
> Pass a `courseUid` from `course_review.search@1`; use the returned
> `teachingTeamUid` and `teacherUid` with `course_review.grade_view@1`.**
> — 教师维度的入口

> **Reads the merged grade distribution of one course, optionally narrowed to
> one teaching team or teacher. Returns score buckets and grade-point buckets
> with sample counts and averages from the community ("own") and supplementary
> ("ham") sources. `found=false` when no distribution is recorded.**
> — `course_review.grade_view@1`

族概述（[V] 原文）：

> **Community course search, teaching teams, grade distributions, public course
> reviews, your own reviews and review eligibility.**

界面上的一句提示（[V] 原文）：

> **Enter a course detail page to view grade distribution and reviews.**

### 调用链

```
① GET  /api/v1/course/grades/by-name?course_name=…      检索课程 → courseUid
   └─ 或 /api/v1/search/simple?query=…                   带 community average rating
② GET  /api/v1/course/grades/teachers/…                  → teachingTeamUid, teacherUid
③ GET  /api/v1/course/grades/view/…                      给分分布（分数段 + 绩点段）
④ GET  /api/v1/reviews/                                  评价正文
   GET  /api/v1/user/reviews                             我看过的/我写的
   GET  /api/v1/user/review-eligibility                  我能不能评
   POST /api/v1/course/grades/…                          提交自己的成绩
   POST /api/v1/reviews/                                 提交评价
```

[V] 路由来自同一份字符串快照的 `/api/v1/*` 清单（426 条），主机是
`https://api-whu-sb.tsinbei.cn`。

### 设计要点

[V] 两个来源被**合并**：`community ("own")` 与 `supplementary ("ham")`。
[推断] `own` = 本站用户自己提交的；`ham` = 另一个补充数据源。分布以**分段
（score buckets / grade-point buckets）+ 样本数 + 均值**的形式返回，而不是逐条成绩
——这是有意的：逐条成绩会泄露个人，分段统计不会。

[V] 贡献是被**资格门槛**限制的：`review-eligibility` 决定你能不能评某门课。
[推断] 门槛的意图是「只让上过这门课的人评」，避免刷分。

**所以「给分」不是学校公开的数据，而是学生自己提交、后端聚合出来的。**

---

## 2. 为什么是空的

[V] 全部实测，只读 GET，不带任何凭据（`api-whu-sb.tsinbei.cn`）：

| 端点 | 结果 | 说明 |
|---|---|---|
| `GET /api/v1/reviews/` | **200** `{"reviews":[],"total":0,"page":1,"limit":20}` | 公开可读，**0 条评价** |
| `GET /api/v1/search/simple?query=高等数学` | 200，14 门课 | 课程库**有数据** |
| 同上，`query=俄罗斯文学` | 200，7 门课 | |
| 同上，`query=数字信号处理` | 200，1 门课 | |
| 同上，`query=舞龙` | 200，4 门课 | |

而**每一门课**的社区字段都是零：

```
review_count=0   average_rating=0   average_difficulty=0
average_teaching_quality=0   average_workload=0   average_course_interest=0
credits=0
```

[V] 需要鉴权的端点（`course/grades/*`、`user/reviews`、`user/review-eligibility`）
一律返回 `401 {"code":"UNAUTHORIZED","business_code":1000}`。它们**可能有数据但我们读不到** ——
这一条不能当成「空」的证据。但它也不构成反证：

- `reviews` 是**公开**的，且为空 —— 这部分与登录无关；
- [V] **带凭据的那条也见过空**：应用自己的诊断面板曾显示
  `GET /api/v1/course/grades/by-name` 返回 `{"course_name":"高等数学","offerings":[]}`
  —— 那是应用持 token 发出的请求，不是未登录探测。但只有这一门课，样本单一。
  （不带凭据直接请求同一路由是 `401`，见 `check_grades.log`。）

**结论 [V]：课程目录是真实的、有数据的；公开可见的社区贡献数据（评价 + 均分）
一条都没有。** 连 `credits` 都是 0，说明这层从未被回填过。

**仍属未决**：`course/grades/view/`（给分分布本体）需要鉴权，我没有用任何账号的
token 去读过它。它**可能**有数据。用真实账号登录后打开一门课的详情页就能确认 ——
这是唯一还没被排除的可能。

---

## 3. 这对 campus-atlas 意味着什么

「查某个老师的历史给分分布和被评结果」**在原版里也是空的**，因为它的数据来自用户贡献，
而没有人贡献。学校的系统（正方教务、商鼎评教）同样不提供：

- 正方教务只有**你自己**的成绩，且查询要过顶象滑块（每次都要）；
- 商鼎评教的学生端是**去评教**的入口，不是**看结果**的入口。

所以这个功能在 `campus-atlas` 里只有一种可行形态：
**自己实现贡献机制** —— 让用户可以提交自己的成绩、撰写评价，由本地/自建后端聚合成分段分布。

这与原版的设计一致，也解释了原版为什么要有「评价资格」这道门槛。

**不该做的事**：不要为了填满界面而伪造分布或评价。原版空着，是因为真的没有数据；
凭空造数字比空着更糟。

---

## 4. ham 生态：功能确实存在，但它不在 `ham-rn` 里

⚠️ **这一节是更正。** 本轮最初只读了一个 React Native 客户端（另一个本地项目），
在它源码里找不到「查老师给分」，于是得出「ham 没有这个功能」——**那个结论是错的**。
功能存在，只是**不在那个仓库**。完整答案在 ham 生态的服务端与文档站里。

### 4.1 [V] 功能存在：`score.proto` 就是那个接口

`github.com/whu-ham/ham-open-proto`（HAM OpenAPI 的 proto 定义）里的 `score.proto`：

```proto
message CourseScoreItem {
  string name = 1;
  string instructor = 2;      // 授课人
  double average = 3;         // 平均分
  int32 total = 4;            // 样本数
  repeated CourseScoreRangeResponseItem range = 5;   // 分数段分布
  string id = 6;
}
message CourseScoreRangeResponseItem {
  int32 from = 1; int32 to = 2; int32 total = 3; string color = 4;
}
service GetCourseScoreService {
  rpc GetCourseScoreItem(GetCourseScoreItemRequest);   // 可按 instructor
  rpc GetCourseScoresByCourseName(...);                // 按课程名分页
}
```

### 4.2 [V] 服务端：`ham-gateway` 的对外端点

`github.com/whu-ham/ham-gateway` 的 README：

```
客户端 ──HTTP/JSON──→ Gateway ──gRPC/mTLS──→ HAM API
                        (Gin)                 (open-api.ham.nowcent.cn:4443)
```

| Method | Path | Query | 说明 |
|---|---|---|---|
| GET | `/api/v1/external/ham/course/search` | `keyword`, `keyword_type` | 搜索课程 |
| **GET** | **`/api/v1/external/ham/score/stat`** | **`course_name`, `instructor`** | **课程成绩统计** |
| **GET** | **`/api/v1/external/ham/score/by-course`** | `course_name`, `page_num`, `page_size` | 该课程名**所有教学团队**的统计 |

鉴权链：`GATEWAY_AUTH_TOKEN` → `HAM_OPEN_APP_ID` / `HAM_OPEN_APP_SECRET` → mTLS 客户端证书。
**这些都是 ham 运营方的密钥，不公开。**

### 4.3 [V] 公开入口：一个 MCP 服务

`whu-ham/whu-ham.github.io` 的文档（`/guide/mcp/config.md`）给出：

| 项 | 值 |
|---|---|
| 地址 | `https://mcp.ham.nowcent.cn/mcp` |
| 传输 | Streamable HTTP |
| 认证 | OAuth 动态注册 / API Key（`ham.nowcent.cn/console/tokens`） |

实测（无 token）：

```
POST /mcp                                  → 401 {"error":"missing authorization token"}
GET  /.well-known/oauth-protected-resource → 200
  {"resource":"https://mcp.ham.nowcent.cn/mcp",
   "authorization_servers":["https://open-api.ham.nowcent.cn"],
   "scopes_supported":["mcp","mcp:read","mcp:write"]}
```

**要读真实给分数据，需要用户本人在 Ham 控制台授权或生成 token。** 这不是技术障碍，
是权限边界：那是 ham 账户的凭据，不该由我去获取。

### 4.4 [V] 数据从哪来：用户每次打开「给分」时上传

`whu-ham.github.io` 的用户手册（`/guide/handbook/score.md`）逐字：

> 使用给分前，你必须：**已获取成绩**；**同意上传匿名成绩至 Ham 的服务器**
>
> Ham 会对需要上传的信息进行脱敏处理，你的学号不会直接上传到服务器，而是**选取特征值**
> 来上传。因此，在 Ham 的服务器中，不能直接查看你的成绩。
>
> **每次你打开"给分"时，Ham 都会将你的成绩上传到服务器中**，用以给其他用户提供参考。
>
> 在搜索框输入课程名或**授课人姓名**，可查询单一课程或**单一授课人**的给分情况。
>
> ## 课程评价
> **在你发布过评论后，才可以查看其他同学的课程评论。**

分享页 `docs/page/coursescore/CourseScoreShareResultView.vue` 的页脚：

> 该给分数据由用户于 {dataTime} 生成，不保证数据实时性。

分享链接的数据**嵌在 URL 里**并用 `md5("v2"+name+instructor+data+dataTime+"uTYbpYG7YSVzncQZ")`
签名 —— 那是客户端完整性校验，不是服务端密钥。

**所以「给分」是「用户上传脱敏成绩 → 服务端按课程/教师聚合成分数段 → 供他人查询」。
数据源是学生自己，不是学校。** 这与 Luotopia 的 `submit_grade` 是同一类设计。

### 4.5 各仓库的角色

| 仓库 | 角色 | 有给分查询吗 |
|---|---|---|
| `ham-rn` | React Native 客户端/组件库，首页 6 卡：天气/课表/成绩/成绩录入/图书馆/绩点 | **没有** |
| `ham-web` | Next.js Web 客户端，带 BFF 代理到 `HAM_BACKEND_ORIGIN` | 未见 |
| `ham-gateway` | Go 网关，对外的 REST | **端点在** |
| `ham-open-proto` | proto 契约 | **在这里**（`score.proto`） |
| `whu-ham.github.io` | 文档站 + 给分分享结果页 | **文档在这里** |

`ham-rn` 里的 `成绩录入`（`GradeEntryScreen`）是**教师录入**，方向相反；`scorecalc/embed/`
里的 `cs.ts`、`sociology.ts` 是**各院系保研 GPA 计算规则**。这些都不是给分查询，
但它们的存在解释了为什么我一开始会以为「ham 没有」——**看了一个客户端就下结论**。

而 Luotopia 那边的 `ham` 是**写的目标**，不是读的来源：

> *"Connect Ham to let Luotopia Server **submit** supported data on your behalf."*

### 4.6 [V] ham 的成绩查询：确实是验证码拦路的

`ham-rn` 的 README 明说：

> **"No captcha is bypassed, anywhere.** The education system gates its score query
> behind an image captcha… **The user solves it in the page; the app reads the result.**"

并交代了架构变更：

> *"What this build adds on top of upstream: **Score query … driven through the education
> system's own pages in a WebView**, reading the XHR replies the page receives."*

也就是：**先做过原生 HTTP，后来改成在 WebView 里驱动学校页面、由人过验证码。**
我在浏览器里观察到「每次查询都出滑块」是对的；我上一轮「原生客户端可能不被挑战」的推断是错的。

[推断] 两条代码路径如何共存：`getScoreList` 的原生 POST 仍是活的（`module.ts:89`、
`FetchScoreView.tsx:33` 都在调），而 `validate` 只是 nonce。最合理的解释是
**同一会话里先在页面过掉滑块，会话被判定为正常后原生的后续查询才通得过**。未单独实测。

**对 campus-atlas 的含义**：成绩查询要显示真实数据，架构上要么有人过验证码，
要么走「驱动学校自己的页面」。纯后台拉取不成立。

### 4.7 [V] ham 修正了一个真实的回退：成绩端点按角色分支

`ham-rn/src/app/GradeEntryScreen.tsx` 引用了教务页面**自己的源码**：

```
url: _path + ($("#jsxx").val() == "xs" ? '/cjcx/cjcx_cxXsgrcj.html'
                                          : '/cjcx/cjcx_cxDgXscj.html')
       + '?doType=query'
```

由这段源码推出的结论是：学生 → `cxXsgrcj`；教师 → `cxDgXscj`；由服务端填的隐藏字段 `jsxx` 决定。
**这个结论已被实测推翻**：见 §5.1。它在本项目里造成了**两次**端点回退，第二次让真实用户拿到 404，
所以这一条留着而不是删掉，作为「引用源码」与「实测」冲突时的记录。

同时拿到真实请求形状（`src/business/education/score/api.ts`）：

```
POST https://jwgl.whu.edu.cn/cjcx/cjcx_cxXsgrcj.html?doType=query&gnmkdm=N305005
body: validate=…&xnm=2025&xqm=3&queryModel.showCount=150
```

- **方法是 POST**，学期在**表单体**里，不在查询串
- **`validate` 不是验证码答案**：`'sl' + Math.floor(Math.random()*1e10).toString(36) + Date.now().toString(36)`
  —— 一个随机标记。ham 这条路径里没有任何验证码处理代码

### 4.8 ham 还给出了两条细节

- **教务的拒绝理由写在页面 JS 里**：`var dlktsxx="…";` —— ham 用一条正则抠出来当错误信息。
  比抽 `#showErrorTip` 更贴近服务端意图。
- **二次认证被显式识别**：`if (res.url.indexOf('ReAuth') !== -1) throw new CasReAuthLoginError(res.url)`。
  ham 也**不自动过**二次认证，只如实报出 —— 与本项目取舍一致。

### 4.9 本轮修正小结

| 项 | 之前 | 现在（依据） |
|---|---|---|
| 「ham 有没有给分查询」 | 没有（只读了 `ham-rn`） | **有**（`score.proto` + `ham-gateway` + 手册） |
| 成绩端点 | `cjcx_cxDgXscj.html`（读菜单） | ~~`cjcx_cxXsgrcj.html`~~ → **`cjcx_cxDgXscj.html`**（§5.1 实测纠正；本行当时的判断是错的） |
| 请求方法 | GET，学期在 query | **POST，学期在表单体** |
| `validate` | 当作「已完成的验证码令牌」 | **随机 nonce**，与验证码无关 |
| 页面大小 | 未发送 | **`queryModel.showCount=150`** |
| 教师分支 | 未记录 | `cxDgXscj.html`，如实写为教师分支 |

## 5. [V] 2026-10-18 实测：一次登录、真表结构、验证码的真实位置

这一轮在一个真学生账号上把整条链跑通了。以下每条都是**观察到**的，不是推出来的。

### 5.1 成绩端点：`cxDgXscj` 才对，`cxXsgrcj` 是 404

同一个已登录的学生会话，两个候选各请求一次（都带 `?gnmkdm=N305005&layout=default`）：

| URL | 结果 |
|---|---|
| `cjcx/cjcx_cxXsgrcj.html` | **404**，文档标题「系统维护页面」 |
| `cjcx/cjcx_cxDgXscj.html` | 标题「学生成绩查询」，有 `xnm`/`xqm` 学期下拉，有 `#tabGrid` |

已登录菜单自己的入口也是 `clickMenu('N305005','/cjcx/cjcx_cxDgXscj.html','学生成绩查询','null')`。

§4.7 引用的那段三元表达式说学生（`jsxx == "xs"`）走 `cxXsgrcj` —— 而实测这个账号**就是学生**，
走的却是 `cxDgXscj`。结论：该表达式在本部署（版本V-9.0）上已经过期，
**菜单 + 实测**才是权威。它还改出了第二次端点回退，并让真实用户拿到 404，所以 §4.7 保留原文并加了纠正标记。

### 5.2 验证码拦的是**成绩查询**，不是登录

干净会话实测：登录一路顺利，没有二次认证；但**一点「查询」**，就出现
`#dx_captcha_basic_overlay_1`，「请拖动左侧滑块还原图片」，表格 0 行。

所以验证码不是「登录失败的惩罚」，而是成绩查询本身的固定关卡。设计由此定下：
滑块由人过，应用只读结果 —— 与 ham 的取舍一致。

顺带修正 §3 里「404 证明不了任何事」的说法：登录后 `cxXsgrcj` **确实** 404，
而同一个会话访问 `cxDgXscj` 得到真页面。未登录时两者分不出来（都落到
`xtgl/login_slogin.html`），但登录后差异明确。

### 5.3 一次登录解锁所有：把浏览器的 cookie 交给应用

之前应用里有**两套互不相干的会话**：自己那套 CAS 客户端（`WhuSession`，内存）和内置浏览器那套
（WebView2 自己的 cookie jar）。**只有浏览器那套能过滑块**，所以人在浏览器里登录完，
应用其它功能仍然是锁着的 —— 这就是「一次登录」一直没实现的原因。

现在：浏览器登录一次 → 抽出 cookie → 用它构造 `WhuSession` → 应用其余功能都用这一套。
实测结果（应用自己的诊断，逐字）：

```
--- handshake ---
browser sign-in: 8 cookies harvested, 8 kept for jwgl.whu.edu.cn

held: SF_cookie_1 @ jwgl.whu.edu.cn/
held: JSESSIONID @ jwgl.whu.edu.cn/
held: CASTGC @ cas.whu.edu.cn/authserver
held: JSESSIONID @ cas.whu.edu.cn/authserver
held: route @ cas.whu.edu.cn/authserver
held: MULTIFACTOR_BROWSER_FINGERPRINT @ cas.whu.edu.cn/
held: happyVoyage @ cas.whu.edu.cn/
held: org.springframework.web.servlet.i18n.CookieLocaleResolver.LOCALE @ cas.whu.edu.cn/
--- request ---
GET /xtgl/index_initMenu.html
--- response (70187 B) ---
```

**必须按 URL 分别去问。** WebView2 匹配 cookie 时同时看 **path**：`CASTGC` 的作用域是
`cas.whu.edu.cn/authserver`，只问 host 拿不到（`whu_endpoints.dart` 已经记录过一次这个真实 bug）。
所以抽取同时问 `https://jwgl.whu.edu.cn/` 和 `https://cas.whu.edu.cn/authserver/`。

这套 cookie 随后让**原生 HTTP 客户端**读到了 70 KB 的真实菜单，没有再登录一次。

### 5.4 成绩表的真实结构：两张表 + `aria-describedby`

```
table.ui-jqgrid-htable         → 表头；每个 th.id 形如 tabGrid_kcmc
table#tabGrid.ui-jqgrid-btable → 数据；每个 td 的 aria-describedby 与 th.id 同串
```

用 `aria-describedby` 反查字段名，比按列名文字匹配可靠得多 —— `学分` 是 `学分绩点` 的子串，
按文字匹配会静默取错列。

两个非数据行要跳过：`jqgfirstrow`（jqGrid 的空占位行）和 `emptyrow`
（内容就是表格自己的话：`请选择筛选条件!` 或 `无数据显示`）。

实测（查询前，真实页面）抽出的表头，23 列，顺序与页面一致：

```
学年 / 学期 / 课程代码 / 课程名称 / 课程性质 / 学分 / 成绩备注 / 绩点 / 成绩性质 /
是否学位课程 / 开课学院 / 课程标记 / 课程类别 / 课程归属 / 教学班 / 任课教师 / 考核方式 /
学号 / 姓名 / 学生标记 / 成绩 / 是否成绩作废 / 学分绩点
```

两条踩过的坑，都已钉进测试：

- **脚本里禁止 `Array.prototype` 的 `map/filter/some/forEach`。** 第一版用了，在真实成绩页上抛
  `cells.some is not a function` —— 正方是老部署，带自己的兼容脚本，内置数组方法不一定是本项目以为的那个。
  改成普通下标循环 + `push` 后正常；`test/jwgl_grade_grid_test.dart` 有测试专门钉住这一点。
- **`ExecuteScript` 对没有完成值的脚本回四个字符 `null`**，和脚本真返回 `null` 无法区分。
  所以脚本把答案写进一个 window 变量，应用**再单独读回来**，不看第一次调用的返回值。

### 5.5 还没验到的部分 → 5.6 已全部补上（2026-10-18 第二轮实测）

5.5 列出的"没验到"，当天晚些时候用页内脚本 + UIA 驱动真实流程全部补齐了。

### 5.6 [V] 端到端全通记录（2026-10-18 下午）：一次登录 → 13 行真成绩

用 `scripts/e2e/run_e2e.py`（UIA 驱动 release exe，凭据走环境变量）把上一轮的
流程跑成了可重复的链路，并首次**在真实页面拿到数据行**。逐时实测：

- **原生 CAS 登录被 reAuth 拦**：`CasLoginScreen` 的 HTTP 登录这次收下密码后
  要求 `/authserver/reAuthCheck/reAuthLoginView.do` 进一步验证（应用如实提示
  「该账号当前要求滑块验证，本应用无法呈现。请先在浏览器里登录一次，再回来重试」）。
  5.2 的「登录一路顺利」不再总成立——风险引擎按请求特征放行/拦截，不是固定的。
- **浏览器内完整登录一次成功，无滑块**：内置浏览器开到 CAS 登录页后，
  脚本用 UIA 填 `#username`（13 字符回读验证）＋ `#password`（Tab 走焦点进入，
  密码框不接受鼠标焦点——试了 3 个点位全部落空，键盘 Tab 1 步即达）→ 点登录
  → 直达教务主页（页头横幅显示本人姓名｜学院｜班级，
  左侧菜单 报名申请/信息维护/选课/信息查询/学生评教… 全部渲染）。
  之前那轮的滑块只在 HTTP 客户端出现，浏览器路径这回没被拦；此处条件一变
  滑块就会再出现（同一轮里切学年的那次查询就被要求滑块），应用不猜、
  也不替人过，属实的边界。
- **接管审计**：`设为应用会话` 弹窗原文
  `已接管这次登录，菜单、学业情况、评教入口现在都用它。` +
  `browser sign-in: 9 cookies harvested, 9 kept for jwgl.whu.edu.cn`
  （弹窗正文是 SelectableText、无 UIA Name，**靠弹窗自己的「复制」按钮经
  剪贴板取回原文**——比对文案要走这条路，别指望 Name）。
- **页面查询按钮** `aid=search_go`；表格 `aid=tabGrid`，23 个列头各有稳定
  AutomationId（`tabGrid_xnmmc/xqmmc/kch/kcmc/…/cj/xfjd`）。页头显示
  **平均学分绩点**（真实服务端数据；本仓库只记形状，不留本人数值）。
- **默认筛选（2026-2027 学年 1 学期）查询**：`共 0 页`／`无数据显示`，
  自检 summary 报 `0 行 · 23 列` + `请选择筛选条件!`——本学期成绩未发布，
  空是**对的**；GPA 数字仍旧显示。
- **切 2025-2026 学年**：自绘下拉没有 ComboBox 暴露；点开后的选项是
  ListItemControl（`2025-2026` 直选即中）。这次查询被**要求滑块**
  （楼梯图 + 「请拖动左侧滑块还原图片」）→ 人拖过后
  **`1 - 13 共 13 条`渲染**。
- **读取成绩（真数据）**：弹层 summary
  `13 行 · 列：学年/学期/…/学分绩点`（23 列全匹配），
  下面是每门课卡片：成绩/绩点/教师/学分/学分绩点/课程性质/学年/学期/课程代码。
- **复制（真数据）**：剪贴板 4267 字符 = summary 行 + 13 条
  `xnmmc=2025-2026 | xqmmc=1 | kch=… | kcmc=… | … | jsxm=… | xh=… | xm=…
  | … | cj=… | xfjd=…`。
  23 字段值全结构化；学号/姓名回显一致（**本仓库不保留真实身份与分数明细**）。
  13 门课覆盖：大学交际英语3／国家安全教育／数据结构与程序设计A／线性代数A／
  思想道德与法治／大学生心理健康／形势与政策1／素质体育1（中期退课）／
  高等数学A1／自然科学经典导引／病毒与生命／遥感影像与生活／地球科学概论。
- **5.5 的两点修正**：数据行的字段映射现在在**真实页面**上验过（不再只是合成页）；
  「查询前 23 列 / 更早 25 列」的不一致依旧存在，但弹窗的 `列：…` 核对法可靠。

复现：`python scripts/e2e/run_e2e.py full [学年]` （凭据走
`E2E_STUDENT_ID`/`E2E_PASSWORD` 环境变量，脚本不含任何真实凭据）；
滑块只属于人，脚本检测到就停下。

### 5.7 [V] 2026-10-18 晚：学生评教（ugsqs）— 三个真实缺陷与两个修复

学生评教在菜单里的形态：**两行同名**。`data-dyym` 的 dropdown 父条目
（`学生评教`，`url=''`，只分组、点击无效）＋末尾扁平化的子条目
（`学生评教`，`N05`，`url=https://ugsqs.whu.edu.cn/caslogin`，可点击）。
列表行的图标列里，评教行是主色实心星（其余行是灰色 chevron）——
用**像素连通域找 13×13 实心图形**可以在合并成一个大控件的语义树里确定行位。

实测暴露的三个缺陷（全部已修，575 测试 + analyzer 绿，2026-10-18 重建）：

1. **body 读取无超时**（`ApiClient`）。响应头有 20s 时限，但
   `http.Response.fromStream`（读 body）**完全无界**——服务器发完头再卡住
   body，屏幕就永久停在 loader，无错无按钮可退。修：`ApiClient.bodyTimeout`
   （默认 30s）＋ `readBody()` 收口所有 body 读取，头/身两段超时分开报错。
2. **跨主机重定向时 cookie 只按起始主机计算**——单点登录断在这里。
   `package:http` 自动跟随重定向会把第一跳的 cookie 头原样重发给所有主机：
   `ugsqs → cas.whu.edu.cn` 的跳转因此从不携带 CASTGC，CAS 自然回登录页。
   修：`ApiClient.getFollowing()` **手动逐跳跟随**，每跳用
   `cookieHeaderFor(该跳 URI)` 重算 cookie，并把各跳 `Set-Cookie` 存进
   本调用内的小 jar（按域匹配）供给后续跳；跳链记录进诊断。
   实测跳链（诊断 sheet 原文）：
   ```
   GET /caslogin
     302 ugsqs.whu.edu.cn/caslogin
     302 ugsqs.whu.edu.cn/caslogin/
     302 cas.whu.edu.cn/authserver/login   ← 这一跳拿到了 CASTGC 并签票
     302 ugsqs.whu.edu.cn/caslogin/
     200 ugsqs.whu.edu.cn/caslogin/
   ```
   CAS 那跳答 302（有票）而非登录页——**一次登录跨系统身份传递打通**。
3. **「目标主机无 cookie」被当成拒绝**。原守卫：`cookieHeaderFor(target)`
   为空 → 直接 Failure（`The session holds no cookie for ugsqs.whu.edu.cn…`）。
   但进入一个从未访问过的系统正是 CAS 通行证存在的意义。修：仅在
   **既无主机 cookie 又无 CAS 通行证**时才拒绝；有通行证即发起，交给逐跳
   cookie 完成 SSO。另：`current.resolve(location)` 的 FormatException
   收进 Result；`jwgl_screen._open/_loadMenu` 与 `teaching_eval_screen._fetch`
   加 try/catch——此前任何逃逸异常都会让 `_busy` 永真（按钮自我禁用、
   点不回来、无任何提示）。

最终 200 响应是 679 B 的 **ugsqs 落地页**（评教系统自己的引导页）：
服务端已把**本人学号**嵌进页面（证明 CAS 票把身份带到了 ugsqs），页面用
`$.ajax POST /loginSSO {userId}` 换 `{success, forwardURL}` 再
`location.href` 跳真正的评教界面。**最后这一步是页面内 JS**：
浏览器/WebView 里由 JS 自然完成；纯报文路径若要进去，需要应用照做这步
两步 POST（`/loginSSO` → `forwardURL`），属下一步工作。
（证据文件在 `%TEMP%\campus_atlas_e2e\`：`z2_body.txt`、`c7_diag.txt`、
`c6_outcome.txt`；含学号，不入库。）

**告警**：当晚多次登录后，CAS 表单出现**静默重渲染**（字段清空、无错误
文案）——应用自己的计划文案就写着该 origin 有登录次数限制
（"without spending one of this origin's limited login attempts"）。
继续频繁登录有被限流/锁号的风险，已停止；**建议改密**。

### 5.8 现状（2026-10-19）：无活动会话，恢复需人工登录一次

- 应用已退出（查无 `campus_atlas.exe` 进程）。`webview2_profile` 里只剩 4 条
  非会话 cookie（CAS 的 `MULTIFACTOR_BROWSER_FINGERPRINT`、locale；jwgl 的
  `_dx_captcha_vid`、`_dx_uzZo5y`）——**CASTGC 是会话级 cookie，关闭即失**，
  没有可直接复用的登录态；成绩与评教都要从「重新登录」开始。
- 20:52 的最后一次整链重试被 CAS 静默重渲染拦在表单页（与上条告警同因，
  限流迹象）——**不再自动重试**，避免把限流升级成锁号。
- 评教纯报文路径的最后一小步：落地页 JS 的
  `POST /loginSSO {userId}` → `forwardURL` 跳转（原文见 `z2_body.txt`），
  照做后才能过落地页进评教界面。
- 恢复方式：改密 → 人工在内置浏览器完成一次登录（有滑块就人过）→
  「设为应用会话」→ 之后可全自动继续。凭据只走环境变量，不入库。

### 5.9 [V] 2026-10-19：本地成绩档案 — GPA 算法、学期趋势、两条导入渠道

成绩只从学校系统读一次，之后在本机回答统计问题。实现在
`lib/features/grades_query/archive/`：

| 文件 | 作用 |
|---|---|
| `grade_models.dart` | `GradeRecord`（学年 / 学期 / 课程名 / 代码 / 教师 / 性质 / 学分 / 成绩文本 / 数值成绩 / 绩点 / 来源）+ JSON |
| `grade_import.dart` | 已读表格 → `GradeRecord`；`scoreFromText` 只接受 0–100 的数值，`优秀`、`W·中期退课` 一律 null |
| `gpa.dart` | 三种算法、`summarizeGrades`、按学期 `termStats`、`passesCourse` |
| `grade_archive_repository.dart` | 一个 JSON 文档；按 key（学年\|学期\|课程代码或课程名）**替换式合并**，重读同一学期只更新不重复 |
| `grade_archive_screen.dart` | 算法与范围选择、GPA、趋势图、课程明细、手工添加 / 删除、清空 |

**算法**（选择持久化在 `grades.gpaStandard` / `grades.requiredOnly`）：

- `whu`：武大官方换算表 —— 90–100→4.0、85–89→3.7、82–84→3.3、78–81→3.0、
  75–77→2.7、72–74→2.3、68–71→2.0、64–67→1.5、60–63→1.0、<60→0；
  GPA = Σ(绩点×学分) ÷ Σ学分。出处：武汉大学信息公开网《武汉大学本科生学籍管理规定
  （修订）》第二十一条（info.whu.edu.cn/info/3781/14965.htm）。
  可与实况交叉核对：2026-10-18 读到的 `大学交际英语3` 是 `cj=90 | jd=4.0 | xfjd=12.00`
  （4.0×3，与表一致），页首服务端 `平均学分绩点 3.56` 是另一个对照项。
- `scale5`：绩点 = (分数 − 50) ÷ 10，60 分起算、满分 5.0，<60 记 0。
- `weighted`：不计绩点，直接给出学分加权平均分。

**计入规则**（写死在一处，测试覆盖）：需要数值成绩且学分 > 0；范围可选「只计必修课」；
等级制 / 退课 / 零学分不进 GPA，但 `优秀`、`合格` 仍算通过学分（`passesCourse`）——
不把 `优秀` 猜成 0 分。

**渠道**：教务（读取成绩表格时自动归档，弹窗显示「已归档 N 条（新增 x · 更新 y）」）+
手工（对话框录入，来源标 `manual`，可单独删除）。`GradeRecord.source` 就是留给研究生
系统等后续渠道的同一个接口。**不存学号与姓名**：表格里有，GPA 用不上。

**未验证的部分**：以上是纯离线逻辑与界面（analyzer 无问题、625 测试全绿），尚未在新的
实况会话上跑一遍「读取 → 归档 → 统计」；会话恢复后按 §5.8 的步骤复跑，并把算出的 GPA
与页首服务端 GPA 对一次。

### 5.10 [V] 2026-10-19：评教入口的最后一跳、评价草稿与学业状态原生页

- **2026-10-19 实况核对（Ham）**：本机存有 2026-10-17 获取、2026-11-16 到期的令牌；
  `tools/list` 返回 **13 个工具**（11 个读 + 2 个「想上列表」写）；`get_course_grade_stats`
  对「高等数学A1」返回 **10 个教学班**（均分 84.42、中位数 87、373 人）。
  **没有**提交成绩或写评论的工具——原版的 `submit_grade` / `create_review` 属于
  Luotopia 自己的后端（§1），不是 Ham MCP；评教表单仍需人工提交。
- **`POST /loginSSO` 已实现**（`lib/features/teaching_eval/ugsqs_repository.dart`）：
  form 字段 `userId`，读 `{success, forwardURL, msg}`，只接受 http(s) 的 `forwardURL`。
  证据仍是 2026-10-18 捕获的落地页 JS（`z2_body.txt`）；**尚未在活会话上执行过**。
- 解析成功后在内置浏览器打开该入口（复用 WebView 屏，隐藏成绩专用按钮）。
  评教表单仍需人工填写并提交：表单契约从未捕获，应用不代填。
- **评价草稿**（`reviews.drafts`）：本地写、改、复制、删；评教页有时限，先在草稿里写好再粘贴。
- **学业状态原生页**：从本地成绩档案算 GPA、已通过/总学分、必修/选修/其他学分构成、
  各学期学分与 GPA、不及格课程；毕业学分要求由用户设定，**未设定时不画进度条**（不编造要求）。
- **Ham 写入**（提交成绩 / 写评价）：Ham MCP 没有这两类工具，`mcp:write` scope 存在但
  工具清单里没有对应项；界面上如实写明，不假装能提交。
- **2026-10-20 增补（我的 Ham，只读）**：`lib/features/grades_query/ham/ham_center_*`
  接入 `get_user_info` / `get_score_rank` / `get_course_want_list` / `get_my_comments` /
  `get_course_comments` / `get_semester_grade_stats`。实况：27 个教学班、评论 8/8、
  2025-1 统计均分 91 / 中位数 92 / 41 人 / 6 段；排名、想上、我的评价该账号为空。
  `get_course_detail` 与 `get_course_detail_by_match` 用同一令牌返回「请重新登录」，
  所以课程详情页由「统计 + 评论 + 学期统计」组合，不依赖它们。
  `create/remove_course_want` 未接：写操作，登录要求未验证。
  复验工具：`dart run tool/ham_center_live.dart`（只打印计数与聚合，不打印昵称/评论/令牌）。
- 测试：`ugsqs_repository_test` 7、`review_drafts_test` 14、`academic_status_test` 8、界面 2。
- 课表、日程与地图见 `docs/timetable-and-map.md`。

### 5.11 [V] 2026-10-20：登录的真实形状——密码之后是二次认证，不是每次都滑块

用户提供的一次 HTTP 登录轨迹（`CasHttpClient`）：

```
POST /authserver/login → 302 →
  /authserver/reAuthCheck/reAuthLoginView.do?isMultifactor=true&service=…
页面 28731 B：短信验证码 / 安全令牌 OTP / 扫码 / 人脸 / 安全问题…
没有 ticket，HTTP 路径停在这里。
```

所以这条路径的失败**不是密码错误，也不是“滑块没做”**：CAS 接受了密码，随后因为
“非可信浏览器”要求**二次认证**。HTTP 客户端无法完成短信/OTP/扫码。

结论：

- **“一次登录解锁全部”仍然成立**，但这一次登录必须在**应用内浏览器**里完成：页面要什么就做什么
  （滑块、短信、OTP、扫码），完成后点右上角钥匙「设为应用会话」。该会话被成绩、课表导入、评教共用。
- `CasLoginScreen`（HTTP 表单）保留为**备用**，仅在账号未被要求二次认证时可用；界面明确标注。
- 登录入口已收进 **设置 → 账户登录**；其他页面的登录墙只提示去那里。
- Ham 给分是另一套授权（Ham token），不在这条 CAS 会话里。

代码：`lib/features/whu_auth/account_login_screen.dart`；入口在 `settings_screen.dart`；
墙上的按钮（`jwgl_screen.dart`、`teaching_eval_screen.dart`、`import_sheet.dart`）都跳到这个页面。

### 5.12 [V] 2026-10-20 晚：一次登录 → 课表（浏览器回退）→ 评教入口，全链实况

本轮把 7 个「部分实现」项里剩下的两条实况链跑通，并修掉两个真缺陷。

**登录路径**（已改）设置 → 账户登录 → 「在应用内浏览器登录」。新脚本
`scripts/e2e/run_e2e_account.py` 走通了它：CAS 表单（`#username` 回读 13 字符 +
Tab 进密码框）→ 登录 → 「设为应用会话」→ 弹窗原文「已接管这次登录……」+
「browser sign-in: 10 cookies harvested, 10 kept for jwgl.whu.edu.cn」→ 设置页显示「已登录」。

#### 5.12.1 N2151 课表：直接 POST 已被页面级验证挡住

- 数据端点 `POST /kbcx/xskbcx_cxXsKb.html` 现在对未验证请求返回 `{"kbList":[]}`（约 510 B），
  页面自己写着「请点击查询进行验证过后查询课表！」。**验证是页面级的**：同一会话里
  先解滑块再直接 POST，仍然是空——绕不过去，也就不该绕。
- 可靠做法因此改成：**在应用内浏览器打开 N2151 → 本人点「查询」并完成滑块 →
  读取页面已经画出来的列表**。新增
  `lib/features/timetable/import/jwgl_timetable_browser.dart`（浏览器页 + 右上角「读取当前课表」）
  与 `jwgl_timetable_page_parser.dart`（把页面行还原成 `kbList` 形状，再交给既有解析器）。
  课表导入面板保留原来的「读取课表」（直接 POST）作为首选，并新增
  「在浏览器中完成验证并读取」作为回退入口。
- 实况：滑块解开后页面 `#kblist_table` 有 32 行（2 行抬头 + 1 行表头 + 20 门课）；
  用**页面里同一份脚本常量**在真实页面上跑，读到 **20 行课程**；应用预览列出
  「一 · 3-4 · 大学物理A（下） · 1-4,6-16 · 1区5-403」「二 · 6-8 · 毛泽东思想和中国特色社会主义
  理论体系概论 · 1-4,6-14 · 1区5-404」等；「覆盖当前课表」二次确认后落盘 20 门课
  （`flutter.timetable.courses.default`），课表页显示「第 7 周」且课程块正确
  （大学物理A（下）/数学物理方法/张量分析与弹性力学/概率论与数理统计A/毛泽东思想…/舞龙1/现代电子实验基础/戏曲审美导论）。
- 学年/学期也从**页面自己的下拉框**读回（`#xnm`=2026、`#xqm`=3=第1学期），
  不用导入面板里的默认值——人在页面上换了学期，导入的周锚点就必须跟着换。
- 表头行（星期 | 节次 | 课表信息）曾被当成一行课程，导入预览里出现假「跳过 1 行」；
  脚本现在要求节次格是数字，表头不再进来（Dart 侧也补了一条守卫测试）。
- **滑块由人（或测试者）拖动，应用不代解**；应用只读已经画出来的行。

#### 5.12.2 评教入口 `/loginSSO`：握手顺序与相对 forwardURL

- 旧行为：只带中央票据 POST `/loginSSO`，服务端答回的 `forwardURL` 是**相对路径**
  （`/studentpj`），旧代码按绝对 URL 校验，于是报「The forwardURL is not an http(s) URL」。
- 现在：先按落地页的路径做一次 CAS 握手（`getFollowing` → `https://ugsqs.whu.edu.cn/caslogin/`，
  拿这一跳建立的会话 cookie），再用这份 cookie POST；相对路径按站点 origin 解析，
  非 http(s) 仍然拒绝。代码：`lib/features/teaching_eval/ugsqs_repository.dart`。
- 实况：解析结果 **已解析到入口 · ugsqs.whu.edu.cn/studentpj**（学号走环境变量，不入库）。
  评教表单仍需在页面里人工填写提交——表单契约尚未取得，应用不代填。

#### 5.12.3 本轮改动与复现

- 新增 `scripts/e2e/run_e2e_account.py`（新登录路径）、`run_e2e_eval.py`（评教入口）、
  `run_e2e_timetable.py`（课表浏览器回退）。
- 驱动脚本本身踩到的三个坑（都记在 `scripts/e2e/run_e2e.py` 里）：
  1. **窗口会跑**：窗口位置在两次运行之间会变，而脚本里的点击全是屏幕绝对坐标；
     现在 `place_window()` 每次都把窗口放到固定位置。
  2. **窗口比 Flutter 视图矮**：runner 的框是 1600×900，视图是 1600×1207，
     语义树报的是**视图坐标**——按框算出来的点会落在屏幕外。窗口因此按视图高度摆。
  3. **前台可能被 DWM 幽灵窗口占住**：别的程序无响应时，Windows 会留一个覆盖屏幕中部的
     Ghost 窗口（实测是卡死的 workbuddy-switch），点击全被它吃掉。现在不再用「前台是不是
     本程序」当安全条件，改成**看这个点是不是落在 app 自己的窗口上**
     （`WindowFromPoint` + 沿父窗口链上溯，内置浏览器是 app 的子窗口，一样算 app 的）。
- 复现：登录 `run_e2e_account.py` → 课表 `run_e2e_timetable.py open` → 人过滑块 →
  `run_e2e_timetable.py read`（读取并覆盖）；评教 `run_e2e_eval.py`。
- 测试：analyzer 绿，**770 测试全绿**（新增 5 条页面解析 + 4 条 forwardURL 解析 + 2 条
  页面学年/学期回读）。
- 告警（不变）：CAS 登录偶发静默失败（页面变 `ERR_CONNECTION_CLOSED`），重试即恢复。
  频繁登录有触发限流的风险；**建议改密**，并轮换 Ham token（2026-11-16 23:36 到期）。

### 5.5 还没验到的部分（如实记·历史）


- **数据行**的字段映射只在合成页面上验过（同结构、同 `aria-describedby`）。
  真实页面上的数据行要**人过滑块**之后才出现，本项目不猜它能过。查询前能验的都验了：
  23 列表头 + `请选择筛选条件!`。
- **列数在查询前后会变**：查询前观察到 23 列，更早一次探测看到 25 列（多 `未来开课学期`、`教研室`）。
  脚本报的是**它当时看到的**列，所以弹窗里那句「列：…」就是核对依据 —— 列不对，一眼看得出。
- **菜单里的评教入口**放在 `data-dyym` 属性里（指向 `ugsqs.whu.edu.cn/caslogin`），不是 `clickMenu`。
  这条用抓下来的真实菜单钉住了（`test/fixtures/jwgl_menu_live.html`，学号已打码）。

### 4.10 对 campus-atlas 的落点

**「给分与评价」不是没有数据可言，而是数据在一个需要授权的外部服务里。**
campus-atlas 若要真做这个功能，有两条合法路径：

1. **用户自带 Ham API Key** — 用户在 `ham.nowcent.cn/console/tokens` 生成，填进应用，
   应用直接调 `https://mcp.ham.nowcent.cn/mcp`。凭据属于用户，可随时吊销。
2. **自建贡献机制** — 用户提交自己的成绩，本地/自建后端聚合成分数段。与原版设计同构，
   但需要规模才有意义。

**不该做的**：伪造分布。原版的数据是真实用户上传的，凭空造数字比空着更糟。
