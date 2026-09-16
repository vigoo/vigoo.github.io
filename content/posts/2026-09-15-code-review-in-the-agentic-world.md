+++
title = "Code review in the Agentic world"
date = 2026-09-15T15:00:00Z
[taxonomies]
tags = ["agents", "code-review"]
+++

## Bottleneck

As everyone nowadays, I am experiencing our usual code review process to be more and more a bottleneck. As several parallel tasks are being developed even by a single developer, it is impossible to keep up with the large number of opened PRs with manual review - even though it is helped by agents - and the non-merged pull requests are often hurting productivity on the follow-up work; some of those unmerged changes are prerequisites to follow-up tasks, or just change some common code that is going to be an extra work to be rebased later. Sometimes the changes in unmerged PRs are relevant for even just _planning_ some of the next steps. One thing you can do then is to show the open PRs to the agent working on the planning session, convincing it to treat them as _done_ and available and not something that's coming later. All this friction is reducing the performance gain we otherwise get from using coding agents.

Things like stacking PRs can help a bit in some long-running epics where follow-up tasks are strictly depending on each other, and where it does not really matter if they get merged one by one or all together - but it's not helping with many relatively independent small tasks, and they can also leads to a lot of pain if more than one such big long-running stack is going on simultaneously. And that seems to be inevitable even with such a small team as ours.

## Why we ask for code reviews?

Why did we make code reviews a mandatory part of our development process? There are a few reasons:

- Most importantly to increase the **quality and correctness of the code** being written. By having additional developers checking what was written, they could often point out details that were missed, edge cases, architectural and styling issues and so on.
- Even if not explicitly defined, **code ownership** exists. Often there are modules primarily written by one developer - this person knows the most of it and asking for their review keeps this ownership alive and also makes sure the change is aligned with their original vision.
- Similar to the previous one, the developed feature may have a **product owner** who wrote the original specification, and any divergence from the original specs may need the their review and approval.
- Regardless of ownership or prior knowledge, reviewing each other's work makes people **up-to-date** about code changes, features and the overall progress of the project.

Submitting a pull-request alone only partially satisfied these requirements. A well written summary in the PR description, _self review comments_ by the author pointing out interesting details, explicitly asking specific team members in comments about some parts; these were all part of the best practices.

### How did it change?

These practices are all either not making sense or increasing becoming the bottleneck in today's world of _agentic coding_. You don't have time to write a detailed description yourself, and because the code was written by the agent anyway, so you generate the description as well. The generated PR description is much harder to understand for humans than a hand-written one, in worst case it even requires another agent to just make any sense of it. 

Others will review the PRs using agents too; it's inevitable as the tools are there, and the amount of changes to review is just growing. Depending on how overloaded each participant is, it may end up just copy-pasting agent output to each other in an interface originally designed for human interaction. Even without that concern, if the review is mostly done by an agent, how different it is from just asking more _agentic reviews_ locally?

If you take your time to interpret and rephrase all the findings yourself, you just get even more behind and frustrated - as well as the PR author, waiting for feedback to unlock the next phases, as I explained in the first section.

## Reducing the load

I propose a system with the overall goal to **reduce the review load** on developers while trying to keep all the above identified original goals of why the review system is in place. The system assumes that every member of the team uses coding agents for implementation, verification and review.

### Self review and CI

A piece of work is done when the developer is confident enough that it's a good enough implementation of the task. This **confidence** must come from a mix of _self-reviewing_ the agent's work, integrating _adversary reviews_, _bug-finder loops_ and similar techniques to the _agentic coding_ session, making sure all the newly written code is tested and testable, and finally, a _draft PR_ is open and all CI checks are green. Details of these techniques are out of scope for this proposal.

The part of making the CI green can (and should) also be part of the _agentic coding_ sessions. Telling the agent to periodically check CI and make all the necessary fixes is OK - but **marking the PR ready** (non-draft) must mean the **human author** is 100% sure the change is ready for that (not necessarily for merging yet, as I will describe below).

Owning your changes is no different from the pre-AI era - everything the agent does in your name is your responsibility.

At this point traditionally we would broadcast the PR link to our team immediately, and then wait for review. The first diversion from the old ways is that at this point the changeset was already checked by multiple _entities_, one being human, others agents. So the quality and correctness point _may be_ already satisfied.

This is a decision point where the developer can **choose to not ask for any further review** and just merge the PR without causing any friction for the others. More precisely, there is a choice to:

- Just merge the PR, no further action needed
- Ask one or more team members for a (partial or full) review 
- Either merging or waiting for review, additional **async communication** can be triggered about the changeset, advertising new features or interesting code changes and so on.

### Asking for a review

When should you ask for a review, instead of just merging it?

There are several possible reasons:

- Not being confident enough about the implementation
- The changeset touches areas which are (implicitly or explicitly) having an _owner_ who needs to know about and approve the changes
- The result diverges from the original plan significantly. Note that changes to the _chunking_ of work does not belong here. If a follow-up changeset will come soon after (in the same milestone), it is not a good enough reason for asking for a review.
- Some (mostly user-facing) behavior needs validation (by multiple team members or the product owner, etc.)

If any of the above is true, the PR (already green, non-draft, passing all the requirements of the previous section) should be sent to the team member(s) you need review from, preferable with an explicit explanation of why the review is needed. The asked review may be **partial** - for example just approve changes to a given module out of the many that has been changed, the author taking responsibility for the correctness of the rest.

### Interesting parts

It is frequent that you _don't_ need a review, or at least not from all team members, but there are still some details about the changeset that you want others to know about. These can be collected and communicated asynchronously, there is no need for the PR to be kept open for this. Everyone can schedule their own time to catch up on this **stream of interesting parts** notifications. They should be pointing to concrete code in the repository with some description of what to look for.

This stream of updates, selected by the authors, is what could keep people **up-to-date** with important changes of the codebase without getting lost in the sea of irrelevant details.

### Walkthroughs

The agents are good in generating **walkthroughs** about a changeset - these are user-friendly, easily readable, good looking and often interactive pages summarizing the changes, focusing on the important aspects. Walkthroughs are useful both when an actual _code review is needed_, and also can be part of the _interesting parts stream_.

Especially with user-facing changes, demonstrating the UX of a new feature as part of the walkthrough helps the reviewers to know what to look for in the changeset, and the other team members to keep up-to-date with the evolution of the product.

## Responsibility

This of course puts a bigger responsibility on the person who decides to **not** ask for a review. In a small team where members are having high trust towards each other, it should not be a problem. What if the system gets abused and people start merging everything without review (and/or without advertising the interesting parts and so on)?

I believe this does not require any defined process - as all changes are still done through commits and PRs linking to issues etc, all information can be retrospectively gathered and whenever someone identifies a merged changeset that shouldn't have been merged, it can be discussed and resolved.

Other options could be to tie the freedom of choosing to merge your own work without further review to some measurable factors, such as the developer's level, time spent in the team, or some way of demonstrating knowledge and skill of working with agents on the project. 

In the end the goal is to reduce the bottleneck caused by code reviews while keeping the code quality and team awareness high.
