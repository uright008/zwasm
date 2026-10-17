;; Calls `wasi:io/poll#poll` with a list length whose byte size overflows u32
;; (0x4000_0000 * 4). The host must answer with the memory trap the ABI defines
;; for a size the address space cannot hold — not wrap (a short buffer would then
;; take `len` elements) and not abort the process with an overflow panic.
(component
  (import "wasi:io/poll@0.2.12" (instance $poll
    (export "poll" (func (param "in" (list u32)) (result (list u32))))))
  (core func $poll (canon lower (func $poll "poll")))
  (core module $M
    (import "poll" "poll" (func $poll (param i32 i32 i32)))
    (memory (export "memory") 1)
    (func (export "run") (result i32)
      (call $poll (i32.const 0) (i32.const 0x40000000) (i32.const 0))
      (i32.const 0)))
  (core instance $deps (export "poll" (func $poll)))
  (core instance $m (instantiate $M (with "poll" (instance $deps))))
  (func $run (result u32) (canon lift (core func $m "run")))
  (export "run" (func $run)))
