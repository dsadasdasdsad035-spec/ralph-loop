---
description: Generate a PRD (Product Requirements Document) for a feature, then save it to tasks/
argument-hint: "[feature description, e.g. 任务优先级系统 / add priority levels to tasks]"
---

Load the `prd` skill and produce a PRD for: $ARGUMENTS

Ask the 3-5 clarifying questions with lettered options first, then write the PRD to
`tasks/prd-[feature-name].md`. Do not implement anything — when the PRD is saved, tell the user to
convert it with `/ralph tasks/prd-[feature-name].md`.
