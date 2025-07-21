# Mofu Mofu Genesis NFT Presale – Aptos Move Contract

**Network:** Mainnet  
**Module Address:** `0xb2adeff0fbd68cb2ec1836e7df4a938f6e76bde1206c19fe4756db86bc1176ac`

---

## Overview

This Move contract implements a presale system for the Mofu Mofu Genesis NFT collection on Aptos. It features stage-based sales, referral tracking, whitelist management, and robust admin controls for managing presale campaigns.

---

## Modules

- `presale` – Main presale logic managing sale stages (start time, end time, sale price, remaining quantity)
- `referral` – Referral code management system to track user invites and commissions
- `whitelist_nft` – NFT token ID whitelist management for exclusive access
- `whitelist` – User address whitelist management for presale participation

---

## Presale Details

### Minting Tiers

- **Mint 1 & 2:** No codes required
- **Mint 3 & 4:** Tier 2 codes (usable 10 times only)
- **Mint 5:** Tier 1 codes (unlimited usage)

### Commission Structure

- **< 10 NFTs:** 10% commission
- **10-19 NFTs:** 13% commission
- **> 19 NFTs:** 15% commission