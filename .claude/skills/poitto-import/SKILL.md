---
name: poitto-import
description: GitHub の親 Issue の URL を受け取り、サブ Issue を1件＝1行として読み、それぞれの中身（本文・リンク先の Notion）から所要時間を見積もって、Artifact「ぽいっと」の WBS か ToDo に書き込む。Use when the user gives a GitHub issue URL and asks to put it into ぽいっと, ToDo, ToDoリスト, やることリスト, or a WBS. Triggers: ぽいっとに入れて, ToDoに入れて, ToDoリストに入れて, やることリストに入れて, WBSにして, サブチケットを見積もって. Not for: 工程をゼロから考える分解（ぽいっとのページの「タスク分解」の役割）
---

# ぽいっとに GitHub Issue を取り込む

「ぽいっと」 https://claude.ai/artifact/NHLvusXoYdBanCFVbh2KHt の WBS か ToDo に、サブ Issue を行として書き込む。
**サブ Issue をそのまま1件＝1行にする。調査・設計・実装…のような工程を新しく作り足さない。** 分解はすでに GitHub 側で済んでいる前提。

## 0. 入れ先を決める

ユーザーの言葉で決める。迷ったら1回だけ聞く。

| 言葉 | 入れ先 |
|---|---|
| 「ToDoに」「やることリストに」 | 最初の ToDo（list は `"todo"`） |
| 「◯◯リストに」「ToDoリスト ◯◯ に」 | 名前が合う既存の ToDo リスト（projects の kind が `"todo"`） |
| 「◯◯（WBS）に」 | 名前が合う既存の WBS（kind が `"wbs"`） |
| 「WBSにして」「ぽいっとに」・指定なし | 新しい WBS を作る |

既存の ToDo リスト・WBS は collection `data/users/me/profile/projects` を `list` して名前で探す。

## 1. 読む（gh）

URL から owner/repo/番号 を取り出し、次を読む。

- 親: `gh issue view <番号> -R <owner/repo> --json title,body,state,url,closedAt`
- サブ Issue: `gh api repos/<owner/repo>/issues/<番号>/sub_issues --paginate`（number, title, state, html_url, body, closed_at）
- サブ Issue がさらにサブ Issue を持つ場合は、もう1段だけ同じように読む（孫まで）

## 2. 中身を読んで見積もる

- **未完了**のサブ Issue だけ中身を読む。本文が `## Notion` とリンクだけなら、Notion コネクタの `notion-fetch` でそのページを読む。完了済みは題名だけで見積もる（読む量を減らすため）
- 見積もりは分単位の3つ: o（順調なら）, m（ふつう）, p（手こずったら）。o <= m <= p、1分単位、最小1分
- 根拠は中身の作業量（触る範囲・未決事項・確認の手間）。決めごと・確認だけのチケットは短く、実装と検証を含むものは長く
- category は工程名を1つ: 調査, 設計, 実装, テスト, レビュー, 調整, ドキュメント, リリース。迷ったら中身の主な作業で選ぶ
- 見積もりの補正は、ぽいっとのページが「見積もりのクセ」で自動で掛けるので、ここでは素の見積もりを書く

## 3. 書き込む（ArtifactData）

URL は `https://claude.ai/artifact/NHLvusXoYdBanCFVbh2KHt`。保存先は利用者本人の領域で、`me` が本人の id に解決される。

- WBS（リスト）: collection `data/users/me/profile/projects`
  - 既存の WBS に入れるか新しく作るかは、ユーザーの指定に従う。指定がなければ新しく作る
  - 新規: doc_id は `p` + base36 の時刻 + 英数字5文字（例 `pmwdz8k1abc12`）。data は `{"name": 親の題名, "goal": "", "kind": "wbs", "createdAt": ISO時刻}`
- タスク: collection `data/users/me/profile/tasks`。doc_id は `t` + base36 の時刻 + 英数字5文字（重ならないように1件ずつ変える）
  - 親 Issue の行: `{"list": WBSのid, "parentId": null, "title": 親の題名, "category": "実装" など, "o":0,"m":0,"p":0, "done": false, "actual": null, "order": 基準時刻ms, "createdAt": ISO時刻, "ref": "#番号", "url": 親のURL}`（子を持つ行の時間は子の合計でページが計算する）
  - サブ Issue の行: `{"list": WBSのid, "parentId": 親の行のid, "title": サブ Issue の題名, "category": 工程, "o", "m", "p", "done": 完了なら true, "actual": null, "order": 基準時刻ms + 連番, "createdAt": ISO時刻, "ref": "#番号", "url": html_url}`。完了なら `"doneAt": closed_at` も付ける
  - title は GitHub の題名をそのまま使う（「[データ移行]」のような接頭辞も残す）
  - url は `https://github.com/<owner>/<repo>/issues/<番号>` の形だけ（ページがそれ以外を無視する）
- **ToDo に入れるとき**は、親 Issue の行を作らず、サブ Issue を平らに並べる（parentId は null）。list は `"todo"` か ToDo リストの id。ほかの項目は上と同じ
- 書き込みは `batch`（1回50件まで）。新規作成なので if_version は付けない
- 書いたあと `list` で件数を確かめる

## 4. 伝える

- 入れた先（WBS か ToDo）の名前、行数（未完了・完了の内訳）、合計の見積もり
- 中身が薄くて題名だけで見積もったチケットがあれば、その件数
- ページを開き直すと反映されること
