+++
title = "Golem 1.5 features - Part 13: Per-agent configuration"
[taxonomies]
tags = ["golem", "durable-execution", "agents", "golem-1.5"]
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
- [Part 10: WebSocket client](/posts/golem15-part10-websocket)
- [Part 11: Bridge libraries](/posts/golem15-part11-bridges)
- [Part 12: REPL](/posts/golem15-part12-repl)
- [Part 13: Per-agent configuration](/posts/golem15-part13-per-agent-config)

## Components vs agents
Previously, in Golem **components** were the most important user-defined entities. Components were the unit of compilation, each transformed to be a **WebAssembly component** and all the customization such as environment variables, initial file system and so on were configurable **per component**.

In **Golem 1.5** the primary entity is an **agent**. Agents are still organized into components - these are the unit of compilation and deployment, but each component can contain an arbitrary number of agents. These agents have to have unique type names in the whole application (that can consist of multiple components) so whenever we refer to a specific agent instance, for example to invoke them or query its metadata or oplog, we no longer need to deal with **component ids** like before. We can identify the agents just by their type name and constructor parameters.

To further continue our journey towards being _agent first_, in the new release all the customization is **per agent**. We can configure everything on the agent level:
- environment variables
- initial file system
- [configuration](/posts/golem15-part7-config-and-secrets)
- [bridge generation](/posts/golem15-part11-bridges)

With this small detail application manifests became much more in sync with how we can configure some other aspects (such as [http routes](/posts/golem15-part1-code-first-routes) and [snapshotting](/posts/golem15-part6-user-defined-snapshotting)) per agent from the code itself.

### Example
The following example shows how we can configure different settings for three agents defined in the same component.

We start with the application's shared runtime settings. We define them as a **component template** so we can apply them to any component in our application, and every agent in those components will get them:

```yaml
manifestVersion: "1.5.0"
app: supportdesk

componentTemplates:
  shared-runtime:
    env:
      RUST_LOG: info
      TZ: UTC
    files:
      - sourcePath: ./shared/ca-certificates.pem
        targetPath: /certs/ca-certificates.pem
        permissions: read-only
    presets:
      local:
        default: true
        env:
          GOLEM_ENV: local
      cloud:
        env:
          GOLEM_ENV: cloud

components:
  supportdesk:agents:
    dir: .
    templates: shared-runtime
```

Then we can provide additional configuration **per agent**. For `InboxAgent` we override the environment, config and initial file system:

```yaml
agents:
  InboxAgent:
    env:
      OPENAI_API_KEY: "{{ OPENAI_API_KEY }}"
      MODEL: gpt-4.1-mini
    files:
      - sourcePath: ./prompts/inbox-system.md
        targetPath: /prompts/system.md
        permissions: read-only
      - sourcePath: ./data/routing-rules.json
        targetPath: /data/routing-rules.json
        permissions: read-only
    config:
      defaultQueue: general
      summarizeReplies: true
      classification:
        confidenceThreshold: 0.75
        labels:
          - billing
          - outage
          - product
```

We can define a completely different set of overrides for the other agents. Note that each agent has its own typed configuration, and we only have to satisfy each agent's own requirements.

```yaml
agents:
  EscalationAgent:
    env:
      JIRA_BASE_URL: https://acme.atlassian.net
      JIRA_TOKEN: "{{ JIRA_TOKEN }}"
      MODEL: claude-3-7-sonnet
    files:
      - sourcePath: ./prompts/escalation-system.md
        targetPath: /prompts/system.md
        permissions: read-only
      - sourcePath: ./playbooks/p1-outage.md
        targetPath: /playbooks/p1-outage.md
        permissions: read-only
      - sourcePath: https://example.com/runbooks/severity-guide.md
        targetPath: /playbooks/severity-guide.md
        permissions: read-only
    config:
      projectKey: OPS
      defaultPriority: high
      pagerduty:
        serviceId: P123456
        autoPageAfterMinutes: 5

  AuditAgent:
    env:
      S3_BUCKET: supportdesk-audit
    files:
      - sourcePath: ./schemas/audit-event.schema.json
        targetPath: /schemas/audit-event.schema.json
        permissions: read-only
    config:
      redactFields:
        - email
        - phone
        - paymentToken
      retentionDays: 90
```

Finally, we can configure the **bridge generator** also per agent:

```yaml
bridge:
  ts:
    agents:
      - InboxAgent
      - EscalationAgent
  rust:
    agents: AuditAgent
```

When we define our **environments** - these are the targets where we can deploy our application to - we can define `componentPresets`. This selects one section from the `presets` map we defined in the first snippet. This feature allows us to have different environment variables / configuration per deployment target!

```yaml
environments:
  local:
    default: true
    server: local
    componentPresets: local
  prod:
    server: cloud
    componentPresets: cloud
```

As demonstrated, the Golem application manifest is very powerful and allows quite complicated setup, even though in its default form it is just a few lines long. To help working on these files, we are publishing a full **JSON schema** for it as well as a dedicated [agent skill](/posts/golem15-part9-skills).
