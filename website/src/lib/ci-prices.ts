// Published pay-as-you-go rates, USD per minute, from each provider's own pricing page.
// Free allowances, volume discounts and electricity are left out. A provider is listed only when its page
// showed the rate; re-check the URL before changing a number.
export type Platform = 'macos' | 'linux';

export interface Rate {
  provider: string;
  /** Runner size the rate applies to, as the page words it. */
  size: string;
  perMinute: number;
  url: string;
}

const github = 'https://docs.github.com/en/billing/reference/actions-runner-pricing';
const blacksmith = 'https://blacksmith.sh/pricing';

export const rates: Record<Platform, Rate[]> = {
  macos: [
    { provider: 'GitHub', size: 'macOS 3-core or 4-core', perMinute: 0.062, url: github },
    { provider: 'Blacksmith', size: 'macOS M4', perMinute: 0.08, url: blacksmith },
  ],
  linux: [
    { provider: 'GitHub', size: 'Linux 2-core arm64', perMinute: 0.005, url: github },
    { provider: 'Blacksmith', size: 'Ubuntu ARM, 2 vCPU', perMinute: 0.0025, url: blacksmith },
  ],
};

/** Base Mac mini, shown as "Buy from $899" (M6 chip, 16GB) on Apple's US store page. */
export const macMini = { price: 899, url: 'https://www.apple.com/shop/buy-mac/mac-mini' };

// arm64 rates, since Noodle's Linux runners are arm64. Presets stay under one Mac's 43,200 minutes in 30 days.
export const minutePresets = [2_000, 5_000, 10_000, 30_000];

/** Days of hosted minutes, at `minutes` per 30-day month, that add up to the Mac mini price. */
export const paybackDays = (minutes: number, perMinute: number) => Math.ceil(macMini.price / ((minutes * perMinute) / 30));

export const money = (n: number) => `$${Math.round(n).toLocaleString('en-US')}`;
