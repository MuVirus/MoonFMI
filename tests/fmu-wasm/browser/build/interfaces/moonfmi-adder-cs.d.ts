/** @module Interface moonfmi:adder/cs@0.1.0 **/
export function getVersion(): string;

export class Fmu implements Disposable {
  constructor()
  getVersion(): string;
  setReal(vr: number, value: number): void;
  getReal(vr: number): number;
  doStep(current: number, step: number): void;
  terminate(): void;
  [Symbol.dispose](): void;
}
