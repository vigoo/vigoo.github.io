+++
title = "Golem 1.5 features - Part 6: User-defined snapshotting"
[taxonomies]
tags = ["golem", "durable-execution", "agents", "golem-1.5", "durability"]
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

## Snapshot based recovery
One of the primary features of **Golem** is that it can recover an agent's state transparently. Under the hood this is implemented by replaying an **oplog** that records every side-effect's results among other things, so we can reconstruct the application's state on recovery. This works perfectly but can be slow if the agent does something CPU-heavy, or it simply have been running long enough to accumulate a long oplog.

One way to fix this slowness is to do periodic **snapshots** - a fully automated snapshotting mechanism would take the snapshot of the agent's memory, file system etc., and during recovery we would only need to replay the part of the oplog that happened _after_ the last snapshot. We did experiments with  automatic snapshotting like this, but it is not part of Golem at the time of writing yet.

In **Golem 1.5** we introduce a new feature that is in some ways more limited, but one can argue that for many use cases even more powerful than the fully automatic snapshotting.

### User-defined snapshotting
Instead of snapshotting automatically the whole memory and other state of an agent, an agent can **opt-in** to snapshot support by implementing a pair of load/save functions. With this the agent only serializes the actual state that matters - but it is no longer transparent, it is something the developer must think through.

Note that the load/save snapshot functions are not really new in Golem 1.5 - we had it since the first release, but previously it was only used as a way to migrate to new versions of an agent when the automatic update was not possible (code leading to diverging replays).

The following example shows how the manually implemented save/load pair would look like for the default template's `CounterAgent`:

{% codetabs() %}
```typescript
@agent()
class CounterAgent extends BaseAgent {
    private readonly name: string;
    private value: number = 0;
    // ...
  
    override async saveSnapshot(): Promise<Uint8Array> {
        const snapshot = new Uint8Array(4);
        const view = new DataView(snapshot.buffer);
        view.setUint32(0, this.value);
        return snapshot;
    }

    override async loadSnapshot(bytes: Uint8Array): Promise<void> {
        let view = new DataView(bytes.buffer);
        this.value = view.getUint32(0);
    }
}
```
```rust
#[agent_implementation()]
struct CounterImpl {
    _name: String,
    count: u32,
}

#[agent_implementation()]
impl CounterAgent for CounterImpl {
    // ...

    async fn load_snapshot(&mut self, bytes: Vec<u8>) -> Result<(), String> {
        let arr: [u8; 4] = bytes
            .try_into()
            .map_err(|_| "Expected a 4-byte long snapshot")?;
        self.count = u32::from_be_bytes(arr);
        Ok(())
    }

    async fn save_snapshot(&self) -> Result<Vec<u8>, String> {
        Ok(self.count.to_be_bytes().to_vec())
    }
}
```
```scala
@agentImplementation()
final class SnapshotCounterImpl(@unused private val name: String) extends SnapshotCounter {
  private var value: Int = 0
  
  // ...

  def saveSnapshot(): Future[Array[Byte]] =
    Future.successful(encodeU32(value))

  def loadSnapshot(bytes: Array[Byte]): Future[Unit] =
    Future.successful {
      value = decodeU32(bytes)
    }

  private def encodeU32(i: Int): Array[Byte] =
    Array(
      ((i >>> 24) & 0xff).toByte,
      ((i >>> 16) & 0xff).toByte,
      ((i >>> 8) & 0xff).toByte,
      (i & 0xff).toByte
    )

  private def decodeU32(bytes: Array[Byte]): Int =
    ((bytes(0) & 0xff) << 24) |
      ((bytes(1) & 0xff) << 16) |
      ((bytes(2) & 0xff) << 8) |
      (bytes(3) & 0xff)
}
```
```moonbit
///|
/// Counter agent with snapshot persistence
#derive.agent
struct CounterAgent {
  name : String
  mut value : UInt64
}

// ...

impl @agents.Snapshottable for CounterAgent with save_snapshot(self) -> Bytes {
  let snapshot = Bytes::make(8, 0)
  let value = self.value

  snapshot[0] = ((value >> 56) & 0xFF).to_byte()
  snapshot[1] = ((value >> 48) & 0xFF).to_byte()
  snapshot[2] = ((value >> 40) & 0xFF).to_byte()
  snapshot[3] = ((value >> 32) & 0xFF).to_byte()
  snapshot[4] = ((value >> 24) & 0xFF).to_byte()
  snapshot[5] = ((value >> 16) & 0xFF).to_byte()
  snapshot[6] = ((value >> 8) & 0xFF).to_byte()
  snapshot[7] = (value & 0xFF).to_byte()

  snapshot
}

impl @agents.Snapshottable for CounterAgent with load_snapshot(
  self,
  bytes : Bytes,
) -> Result[Unit, String] {
  if bytes.length() != 8 {
    return Err("Invalid snapshot length: expected 8, got " + bytes.length().to_string())
  }

  let value =
    (bytes[0].to_uint64() << 56) |
    (bytes[1].to_uint64() << 48) |
    (bytes[2].to_uint64() << 40) |
    (bytes[3].to_uint64() << 32) |
    (bytes[4].to_uint64() << 24) |
    (bytes[5].to_uint64() << 16) |
    (bytes[6].to_uint64() << 8) |
    bytes[7].to_uint64()

  self.value = value
  Ok(())
}
```
{% end %}

### Recovery configuration
Defining the pair of snapshotting functions is enough to use these for **updating agents** but it does not enable **snapshot-based recovery**. We can configure that through the agent annotation:

{% codetabs() %}
```typescript
@agent({ snapshotting: { periodic: '5s' } })
class CounterAgent extends BaseAgent {
  // ...
}
```
```rust
#[agent_definition(snapshotting = "periodic(5s)")]
trait CounterAgent {
    // ...
}
```
```scala
@agentDefinition(snapshotting = "periodic(5 seconds)")
trait CounterAgent extends BaseAgent {
  // ...
}
```
```moonbit
#derive.agent(snapshotting="periodic(5)")
pub struct CounterAgent {
}
```
{% end %}

The options can be `disabled`, `enabled` to use the server-side default (which is set to disabled by default), `every(N)` meaning snapshot after every _Nth_ oplog entry, or `periodic(5s)` to make a snapshot every 5 seconds.

### Default implementation
Having snapshot-based recovery is really useful but we realized that writing these manual serialization functions may be too painful. In **Golem 1.5** each supported language has a mechanism to opt-in for a **default snapshotting implementation** while still allowing defining a fully custom pair of methods like we've seen above.

{% codetabs() %}
```typescript
class CounterAgent extends BaseAgent {
  // For TypeScript, simply NOT defining loadSnapshot and saveSnapshot will 
  // provide a default implementation that saves/loads the agent class itself 
  // as JSON
}
```
```rust
#[derive(Serialize, Deserialize)]
struct CounterAgentImpl {
    count: u32,
    #[serde(skip)]
    _id: String,
}

#[agent_implementation]
impl CounterAgent for CounterAgentImpl {
    // Not overriding save_snapshot and load_snapshot will provide the 
    // default implementation, if the agent type has serde Serialize 
    // and Deserialize instances
}
```
```scala
// For Scala we need to explicitly define the state to be serialized
// and mix-in the `Snapshotted[T]` trait

final case class SnapshotCounterState(value: Int)
object SnapshotCounterState {
  implicit val schema: Schema[SnapshotCounterState] = Schema.derived
}

@agentImplementation()
final class CounterAgentImpl(@unused private val name: String)
    extends CounterAgent
    with Snapshotted[SnapshotCounterState] {

  var state: SnapshotCounterState                                 = SnapshotCounterState(0)
  val stateSchema: Schema[SnapshotCounterState] = SnapshotCounterState.schema
}
```
```moonbit
#derive.agent(snapshotting="every_n(1)")
struct Counter {
  name : String
  mut value : UInt64
} derive(ToJson, @json.FromJson)

// If an agent derives ToJson/FromJson and has no manual Snapshottable instance,
// the SDK provides a default implementation
```
{% end %}

### Observability
Using the default snapshotting implementation, or implementing one by hand that uses the `application/json` content type has one more nice feature: when observing the **oplog** of an agent for debugging purposes, we can see the snapshot entries with the serialized JSON state!

Let's see an example:

```
#00021:
INVOKE COMPLETED
          at:                2026-04-15T13:19:04.618Z
          consumed fuel:     200796
          result:            AgentMethod(AgentInvocationOutputParameters { output: Tuple(ElementValues { elements: [] }) })
#00022:
SNAPSHOT
          at:                2026-04-15T13:19:04.619Z
          data:              {
  "principal": {
    "tag": "anonymous"
  },
  "state": {
    "name": "test1",
    "value": 5
  },
  "version": 1
}
#00023:
ENQUEUED INVOCATION increment
          at:                2026-04-15T13:19:05.355Z
          idempotency key:   3da50be7-f426-427b-8f50-a05ced00d20a
```
