;; A component with zero imports and one core module: the `.single` path, which
;; pins the interpreter. `run` spins for several seconds, so a test can interrupt
;; it from another thread and observe error.Interrupted instead of a hang.
(component
  (core module $M
    (memory (export "memory") 1)
    (func (export "run") (result i32)
      (local $i i32)
      (block $done
        (loop $l
          (br_if $done (i32.ge_u (local.get $i) (i32.const 20000000)))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $l)))
      (i32.const 7)))
  (core instance $m (instantiate $M))
  (func $run (result u32) (canon lift (core func $m "run")))
  (export "run" (func $run)))
