interface Env {
  RELAY_TOKEN: string;
}

interface SubtleCrypto {
  timingSafeEqual(a: ArrayBuffer, b: ArrayBuffer): boolean;
}
