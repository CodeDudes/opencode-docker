---
description: Perform a comprehensive code quality and security review on staged git changes
---

Please perform a thorough code review of the following staged git diff:

!`git diff --staged`

Evaluate the changes across these dimensions:
1. **Security & Vulnerabilities:** Check for hardcoded secrets, injection vectors, unvalidated inputs, or permission regressions.
2. **Logic & Edge Cases:** Identify unhandled exceptions, null pointer references, concurrency issues, or off-by-one errors.
3. **Architecture & Clean Code:** Ensure the changes follow idiomatic conventions and maintain readability.
4. **Testing:** Highlight any missing unit tests or regression scenarios.

Format your review with clear severity levels:
* 🚨 **Critical:** Must fix before merging.
* ⚠️ **Warning:** Should be addressed or justified.
* 💡 **Suggestion:** Code style or minor improvement.
