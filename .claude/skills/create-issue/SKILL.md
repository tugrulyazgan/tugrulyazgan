---
name: create-issue
description: Create GitHub issues from natural language descriptions. Auto-detects issue type (feature/bug) from context, reads repo issue templates, collects missing info from codebase or by asking the user, and previews before creating. Trigger when user says "create issue", "file a bug", "open an issue", "new feature request", "report a bug", or similar intent to create a GitHub issue.
---

# Create Issue

Create a well-structured GitHub issue from a brief user description, minimizing back-and-forth.

## Workflow

### 1. Discover templates

Read all `.github/ISSUE_TEMPLATE/*.yml` files in the repo root. Parse each template's `name`, `labels`, and `body` fields to learn available issue types and their required/optional sections.

If no templates directory exists, use plain `gh issue create` with title + body.

### 2. Classify issue type

Infer the template from the user's wording:
- Bug signals: "bug", "broken", "crash", "error", "wrong", "regression", "fix", "不对", "出错", "崩溃", "问题"
- Feature signals: "add", "feature", "new", "support", "enhance", "improve", "want", "wish", "希望", "添加", "新增", "支持"

If ambiguous, ask the user to pick from the available template names.

### 3. Gather information

For each template field:

1. Map what the user already provided to the corresponding field.
2. Auto-collect when possible — grep for error messages, read related source files, check `git log` for recent changes in the area.
3. Ask only for **required** fields that cannot be inferred. Batch all questions into one message.
4. For optional fields, fill in what can be inferred; leave the rest blank.

### 4. Preview

Present a formatted preview:

```
## Issue Preview

**Type:** <template name>
**Title:** <title>
**Labels:** <labels>

---

<full issue body as it will appear on GitHub>
```

Ask: "确认创建？如需修改请告诉我。" Wait for user confirmation.

### 5. Create

On confirmation, run `gh issue create` with `--label` and `--title`, passing body via HEREDOC. Print the resulting URL.

Note: `--template` and `--body` cannot be combined in `gh`. Always use `--body` with the fully composed content.
