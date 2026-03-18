# Abstraction Best Practices
**The core test:** *If this abstraction disappeared tomorrow, would engineers be helpless or mildly inconvenienced?*

---

**I. Abstract when the intent-to-invocation gap is large and domain-unrelated**
If expressing what you want to do requires substantial repeated work unrelated to the domain problem itself, an abstraction is justified. The abstraction should close exactly that gap — no more. When the gap is small or inherently domain-specific, abstraction adds indirection without value.

**II. Add abstraction layers only when you have mastered the base layer**
Abstraction aids the base layer, it does not replace it. Users may use both — abstraction should speed up common work and handle corner cases. Building an abstraction without mastering the base layer produces one that leaks at the wrong seams.

**III. Handle the boilerplate, expose the domain logic**
Abstract away toil (state management, retries, boilerplate). Never abstract away domain knowledge — what the system is actually doing and why. Engineers should finish an operation knowing more about the domain, not less.

**IV. Use the abstraction, understand the domain**
Engineers using the abstraction should understand the underlying domain, not just the abstraction's vocabulary. When something goes wrong, the abstraction will not save them — domain knowledge will.

**V. Stay thin, stay composable**
A good abstraction is a shortcut to the underlying technology, not a replacement for it. Engineers should be able to see through it or bypass it when needed. Thickness accumulates gradually — every convenience added without a corresponding escape hatch makes the abstraction harder to outgrow.

**VI. Always leave a way out**
If an engineer needs to do something the abstraction does not explicitly support, they must be able to — without breaking the abstraction or forking the tooling. An abstraction with no escape hatch eventually becomes a cage.

**VII. Validate at the boundary, fail early**
Validate all inputs and preconditions before any side effects. Failures discovered mid-operation are harder to recover from and harder to reason about. A clean rejection at the door is always preferable to a half-completed state.

**VIII. Consistent output is part of the contract**
Consistent, structured feedback (success, skipped, failed, summary) across all operations reduces the cognitive cost of reading and comparing results. Inconsistent output forces engineers to interpret rather than read, which is toil the abstraction should have eliminated.

**IX. The abstraction's vocabulary should map to the underlying domain's vocabulary**
If engineers need to learn a new conceptual model on top of the underlying domain, the abstraction has grown too thick. Names, concepts, and objects should remain recognizable to someone reading the base layer's documentation. Vocabulary drift is the first sign an abstraction has stopped being a shortcut and started being a framework.

**X. Train engineers, don't hide complexity from them**
When engineers lack domain knowledge, the right solution is training or documentation. An abstraction that hides the gap avoids the decision rather than resolving it. Complexity hidden is complexity deferred — it will surface at the worst possible moment.