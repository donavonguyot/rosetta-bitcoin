import { COIN, SUBSIDY_HALVING_INTERVAL } from "./constants.js";

export function blockSubsidy(height: number): number {
  if (height < 0) return 0;
  const halvings = Math.floor(height / SUBSIDY_HALVING_INTERVAL);
  if (halvings >= 64) return 0;
  return Math.floor((50 * COIN) / 2 ** halvings);
}
