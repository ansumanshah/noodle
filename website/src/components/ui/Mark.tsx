// The Noodle mark as a small inline image. Source file: public/assets/favicon.svg.
export function Mark({ size = 28 }: { size?: number }) {
  return <img src="/assets/favicon.svg" width={size} height={size} alt="" aria-hidden="true" />;
}
