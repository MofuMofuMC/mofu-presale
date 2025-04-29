
# Mofu Mofu Genesis NFT Bridge – Aptos Move Contract

**Network:** Testnet  
**Module Address:** `0xb46203f5d5ee9fbda8bacc891a08e401d73fbc93096d0de13636a503b670b9db`

---

## Overview

This Move contract implements a cross-chain NFT bridge for the Mofu Mofu Genesis collection, enabling secure NFT transfers from Ethereum to Aptos. It features validator-based signature verification, pre-minting, claim logic, and robust admin controls.

---

## Modules

- `bridge::bridge` – Main bridge logic, validator management, claim, and record creation.
- `bridge::bridge_message` – Message hash and signature verification utilities.
- `bridge::mofu_nft` – NFT minting, collection management, and royalty logic.

---

## Deployment

```sh
aptos move publish --profile <your-profile> --assume-yes
```