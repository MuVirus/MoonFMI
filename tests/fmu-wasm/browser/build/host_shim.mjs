export const captured = [];
export function log(level, message) {
  captured.push({ level, message });
}
