The `tests` axis now reaches everyone who writes a test.

`test-frameworks` is a new skill with one section per value of the axis — JUnit5, JUnit4, Kotest —
each saying how a test is declared so the runner collects it, how it asserts, its lifecycle hooks,
parameterization, asynchronous tests, how its failure reads in the report and what the build needs
to run it. A separate section lists the surfaces that force a framework whatever the axis says: the
Compose rule, Robolectric, an instrumented test, `commonTest`, `@QuarkusTest`. The manifest answers
core's new **testing** topic with it.

The block the four testers share no longer teaches JUnit5 hooks as the default, `kotlin-server-tester`
says what a Spring slice, a Testcontainers container and a Ktor `testApplication` become under each
value, the three developers and `kotlin-diagnostics` name the framework of the regression test they
write, and `kotlin-init` writes the placeholder test and its build wiring from the skill instead of
from its own memory.

The floor on `spine-toolkit` moves to `>=2.5.0 <3`: the agents that write test code name
`spine-toolkit:test-authoring`, which core added in 2.5.0.
