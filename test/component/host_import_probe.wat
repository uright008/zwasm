;; Custom host import fixture: the component imports `snooze:host/probe` (not a
;; WASI interface) and re-exports whatever the host's `answer` returns. The fork
;; links it only when the embedder registers that interface on the Host.
(component
  (import "snooze:host/probe@0.1.0" (instance $probe
    (export "answer" (func (result u32)))))
  (core func $answer (canon lower (func $probe "answer")))
  (core module $M
    (import "probe" "answer" (func $answer (result i32)))
    (func (export "run") (result i32) (call $answer)))
  (core instance $deps (export "answer" (func $answer)))
  (core instance $m (instantiate $M (with "probe" (instance $deps))))
  (func $run (result u32) (canon lift (core func $m "run")))
  (export "run" (func $run)))
