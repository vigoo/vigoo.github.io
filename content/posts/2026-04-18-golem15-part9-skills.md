+++
title = "Golem 1.5 features - Part 9: Agent skills"
date = 2026-04-18T11:50:00Z
[taxonomies]
tags = ["golem", "durable-execution", "agents", "scala", "golem-1.5", "ai"]
+++

## Introduction
I am writing a series of _short_ posts showcasing the new features of **Golem 1.5**, to be released at the end of April, 2026. The episodes of this series will be short and assume the reader knows what Golem is. Check my [other Golem-related posts](https://blog.vigoo.dev/tags/golem/) for more information!

Parts released so far:
- [Part 1: Code-first routes](/posts/golem15-part1-code-first-routes)
- [Part 2: Webhooks](/posts/golem15-part2-webhooks)
- [Part 3: MCP](/posts/golem15-part3-mcp)
- [Part 4: Node.js compatibility](/posts/golem15-part4-nodejs)
- [Part 5: Scala support](/posts/golem15-part5-scala)
- [Part 6: User-defined snapshotting](/posts/golem15-part6-user-defined-snapshotting)
- [Part 7: Configuration and Secrets](/posts/golem15-part7-config-and-secrets)
- [Part 8: Template simplifications and automatic updates](/posts/golem15-part8-template-simplifications)
- [Part 9: Agent skills](/posts/golem15-part9-skills)

## Skills 
Using coding agents has become a standard way of writing code. With **Golem 1.5**, our application templates include an `AGENTS.md` and a huge catalog of **agent skills** describing every detail of creating, modifying and testing agents on the Golem platform.

A bootstrap skill explaining the `golem new` command is going to be available through [skills.sh](https://skills.sh); then depending on the chosen programming language, a large set of Golem specific skills get unpacked to the application's directory.

### Common and per-language skills
The skill catalog is still being finalized for the release, but we will have 10-15 language-independent skills, and about 25-30 additional skills **for each language** (TypeScript, Rust, Scala and MoonBit). 

We are running a benchmark with popular coding agents to see how well they can use these skills and this benchmark will run daily on CI from now on, making sure we can keep up with the rapidly changing ecosystem of coding agents.

### Areas covered
The skills cover every aspect of writing and running applications on the Golem platform:

- Creating new projects or extending existing ones
- Adding dependencies
- Configuring applications
- Writing new agents
- Exposing agents through HTTP and MCP
- Communication between multiple agents
- Working with databases
- Calling external services
- Integration with AI providers
- Creating webhooks
- Using advanced features like transactions, snapshotting, etc
- Troubleshooting

Every new feature Golem gets starting from 1.5 will immediately have full support for agentic development.
