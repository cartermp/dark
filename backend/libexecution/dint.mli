type t [@@deriving ord, eq, yojson, show]

val of_int : int -> t

val to_int : t -> int option

val to_int63 : t -> Core_kernel.Int63.t

val of_int63 : Core_kernel.Int63.t -> t

val to_int_exn : t -> int

val of_float : float -> t

val to_float : t -> float

val of_string_exn : string -> t

val to_string : t -> string

val random : t -> t

val init : unit -> unit

val ( + ) : t -> t -> t

val ( - ) : t -> t -> t

val ( / ) : t -> t -> t

(** [modulo value modulus] performs modular arithmetic. [modulus] must be positive or will throw an exception. *)
val modulo_exn : t -> t -> t

(** [rem value divisor] returns the remainder after dividing [value] by [divisor]. Throws an exception if [divisor] is [0]. *)
val rem_exn : t -> t -> t

val ( * ) : t -> t -> t

val max : t -> t -> t

val min : t -> t -> t

(** [clamp value ~min ~max] returns the result of clamping [value] between [min] and [max]. *)
val clamp : t -> min:t -> max:t -> t Base__.Or_error.t

val pow : t -> t -> t

val abs : t -> t

val negate : t -> t

val one : t

val zero : t
