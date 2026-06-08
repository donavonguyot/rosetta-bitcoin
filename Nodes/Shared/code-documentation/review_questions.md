# Code Documentation Review Questions

Use these questions when reviewing a documentation batch. They are judgment
prompts, not a coverage checklist.

## Usefulness

- Does the new text help an agent skim the file faster?
- Does it help a human reviewer understand a Bitcoin rule, failure mode, or
  design decision?
- Is the explanation at the right altitude, or should it move to an architecture
  doc or Shared contract?

## Correctness

- Does the comment describe what the code actually does?
- Does it avoid claiming current status, benchmark rank, lifecycle posture, or
  binary-gate state?
- Does it distinguish runtime truth from Project projection?
- Does it preserve port independence instead of implying another port is an
  oracle?

## Brevity

- Could a shorter comment preserve the same invariant?
- Is it explaining obvious syntax or control flow?
- Does it duplicate a Shared document instead of linking or naming it?

## Native Style

- Would an expert in this language expect documentation in this location and
  form?
- Does the prose fit the surrounding code style?
- Does it avoid forcing one port's wording onto another language?

## Agent Hygiene

- Are canonical phrases grep-friendly and sparse?
- Would loading this file into context become easier, not harder?
- Are permanent work queues, hard tiers, or file inventories creeping back in?
