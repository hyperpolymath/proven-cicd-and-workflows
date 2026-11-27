// Conformance input: one instance of every syntax node the visitor scopes.
// Never compiled; parsed by creusot-source-facts in tests/proven_facts.rs.
#![logic]
extern crate core as k;
use core::mem;
type Bare = fn(#[logic] x: u8);
type BareVariadic = unsafe extern "C" fn(x: u8, #[logic] ...);
trait Alias = Clone;
#[logic]
struct Generic<'a, #[logic] T, #[logic] const N: usize> {
    #[logic]
    field: &'a [T; N],
}
union U {
    a: u8,
}
enum E {
    #[logic]
    V,
}
static S: u8 = 0;
#[cfg_attr(creusot, logic)]
const C: u8 = 0;
macro_rules! m {
    () => {};
}
m!();
extern "C" {
    #[trusted]
    fn foreign(x: u8, ...);
    static FS: u8;
    type FT;
    m!();
}
trait T {
    #[logic]
    const TC: u8;
    type TT;
    #[requires(true)]
    fn t(&self);
    m!();
}
impl T for u8 {
    const TC: u8 = 0;
    type TT = u8;
    #[ensures(result == ())]
    fn t(&self) {}
    m!();
}
#[creusot::logic]
#[creusot_contracts::predicate]
#[creusot_std::macros::law]
#[other::ensures(true)]
fn every_expression(mut a: [u8; 3], b: Option<u8>) -> Result<u8, u8> {
    let arr = [1, 2];
    a = [0; 3];
    let fut = async {};
    let _ = fut.await;
    let sum = 1 + 2;
    let block = { 1 };
    let brk = loop {
        if b.is_some() {
            break 1;
        }
    };
    let call = mem::size_of::<u8>();
    let cast = 1u8 as u16;
    let closure = |x: u8| x;
    let konst = const { 1 };
    for _ in 0..1 {
        continue;
    }
    let field = (1, 2).0;
    if let Some(v) = b {}
    let index = arr[0];
    let infer: [u8; 1] = [_; 1];
    let lit = 1;
    let mac = m!();
    let mat = match b {
        Some(1 | 2) => 1,
        Some(ref r) => 2,
        Some((x)) => 3,
        _ => 0,
    };
    let method = closure.clone();
    let paren = (1);
    let path = S;
    let range = 0..1;
    let raw = &raw const lit;
    let reference = &lit;
    let strukt = Generic { field: &[0u8; 1] };
    let Generic { field } = strukt;
    let [first, ..] = arr;
    let (p, q) = (1, 2);
    let Some(w) = b else { return Ok(0) };
    let &deref = &1;
    let tried = b.ok_or(0)?;
    let tryblock = try { 1 };
    let tuple = (1, 2);
    let neg = -1;
    let uns = unsafe { 1 };
    while false {}
    let y = yield 1;
    proof_assert!(true);
    #[cfg(creusot)]
    proof_assert!(true);
    #[cfg(not(creusot))]
    proof_assert!(false);
    m!();
    return Ok(1);
}
#[cfg(test)]
mod hidden {
    #[ensures(false)]
    fn not_counted() {}
}
#[cfg_attr(creusot, cfg(test))]
mod also_hidden {
    #[ensures(false)]
    fn not_counted() {}
}
#[cfg_attr(not(creusot), cfg(feature = "x"))]
mod present {
    #[cfg_attr(all(), variant(x))]
    #[cfg_attr(any(), ensures(false))]
    #[cfg_attr(any(creusot, feature = "x"), invariant(true), open, terminates, pure)]
    fn counted() {}
}
