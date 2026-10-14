(component
  (import "wasi:io/poll@0.2.0" (instance $poll
    (export "pollable" (type $p (sub resource)))
    (export "[method]pollable.ready" (func (param "self" (borrow $p)) (result bool)))))
  (core func $ready (canon lower (func $poll "[method]pollable.ready")))
  (core module $M
    (import "io" "ready" (func $ready (param i32) (result i32)))
    (func (export "run") (result i32) (drop (call $ready (i32.const 999))) (i32.const 0)))
  (core instance $deps (export "ready" (func $ready)))
  (core instance $m (instantiate $M (with "io" (instance $deps))))
  (func $run (result (result)) (canon lift (core func $m "run")))
  (component $Run (import "f" (func $f (result (result)))) (export "run" (func $f)))
  (instance $r (instantiate $Run (with "f" (func $run))))
  (export "wasi:cli/run@0.2.0" (instance $r)))