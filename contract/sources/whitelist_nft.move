module presale::whitelist_nft {
    #[test_only]
    use std::signer;
    // use std::error;
    use std::option::{Self};
    use aptos_std::smart_table::{Self, SmartTable};
    use aptos_framework::object::{Self, Object, ObjectCore};
    use aptos_framework::event::{Self};

    friend presale::presale;

    /// Errors
    // const ENOT_AUTHORIZED: u64 = 1;
    const EWHITELIST_REGISTRY_NOT_EXISTS: u64 = 2;
    const ENFT_ALREADY_WHITELISTED: u64 = 3;
    const ENFT_NOT_WHITELISTED: u64 = 4;
    const ENFT_ALREADY_USED: u64 = 5;
    const ENOT_OWNER_OF_NFT: u64 = 6;

    /// Struct to store whitelist NFT registry
    struct WhitelistNFTRegistry has key {
        /// Smart table that maps NFT object IDs to minting status
        whitelist: SmartTable<address, NFTMintingStatus>
    }

    /// Struct to store NFT minting status
    struct NFTMintingStatus has store, drop {
        /// The address of the authorized minter
        minter: option::Option<address>,
        /// Whether the NFT has been used to mint
        is_minted: bool
    }

    // Event emitted when an NFT is added to the whitelist
    #[event]
    struct NFTAddedToWhitelist has drop, store {
        nft_id: address
    }

    // Event emitted when an NFT is used for minting
    #[event]
    struct NFTUsedForMinting has drop, store {
        nft_id: address,
        minter: address
    }

    /// Initialize the whitelist NFT registry
    public(friend) fun init_whitelist_nft_config(admin: &signer) {
        // let admin_addr = signer::address_of(admin);

        // Create and store the whitelist registry
        let whitelist_registry = WhitelistNFTRegistry { whitelist: smart_table::new() };

        move_to(admin, whitelist_registry);
    }

    /// Add an NFT to the whitelist
    public(friend) fun add_nft_to_whitelist(nft_id: address) acquires WhitelistNFTRegistry {
        assert_whitelist_nft_registry_exists();
        // Get the whitelist registry
        let registry = borrow_whitelist_nft_registry_mut();

        // Check that the NFT is not already whitelisted
        assert!(
            !smart_table::contains(&registry.whitelist, nft_id),
            ENFT_ALREADY_WHITELISTED
        );

        // Create the NFT minting status
        let status = NFTMintingStatus { minter: option::none(), is_minted: false };

        // Add the NFT to the whitelist
        smart_table::add(&mut registry.whitelist, nft_id, status);

        // Emit event
        event::emit(NFTAddedToWhitelist { nft_id });
    }

    public(friend) fun remove_nft_from_whitelist(nft_id: address) acquires WhitelistNFTRegistry {
        assert_whitelist_nft_registry_exists();
        // Get the whitelist registry
        let registry = borrow_whitelist_nft_registry_mut();
        // Check that the NFT is whitelisted
        assert!(
            smart_table::contains(&registry.whitelist, nft_id), ENFT_NOT_WHITELISTED
        );
        // Remove the NFT from the whitelist

        smart_table::remove(&mut registry.whitelist, nft_id);
    }

    /// Mark an NFT as used for minting
    public(friend) fun mark_nft_as_used(
        user: address, object: Object<ObjectCore>
    ) acquires WhitelistNFTRegistry {
        assert!(object::is_owner(object, user), ENOT_OWNER_OF_NFT);
        // Get the whitelist registry
        let registry = borrow_whitelist_nft_registry_mut();
        let nft_id = object::object_address(&object);
        // Check that the NFT is whitelisted
        assert!(
            smart_table::contains(&registry.whitelist, nft_id), ENFT_NOT_WHITELISTED
        );

        // Get the NFT minting status
        let status = smart_table::borrow_mut(&mut registry.whitelist, nft_id);

        // Check if the NFT has already been used
        assert!(!status.is_minted, ENFT_ALREADY_USED);
        // Mark the NFT as used
        status.is_minted = true;
        status.minter = option::some(user);

        // Emit event
        event::emit(NFTUsedForMinting { nft_id, minter: user });
    }

    // Check if whitelist configuration exists for a given module address
    #[view]
    public fun whitelist_config_exists(module_address: address): bool {
        exists<WhitelistNFTRegistry>(module_address)
    }

    // Check if an NFT is eligible for minting and verify ownership
    #[view]
    public fun is_eligible_for_mint(object: Object<ObjectCore>): bool acquires WhitelistNFTRegistry {
        // Return 0 if whitelist config doesn't exist
        if (!whitelist_config_exists(@presale)) {
            return false
        };

        let registry = borrow_whitelist_nft_registry();

        let nft_id = object::object_address(&object);
        // Check if the NFT is in the whitelist
        if (!smart_table::contains(&registry.whitelist, nft_id)) {
            return false
        };

        // Get the NFT minting status
        let status = smart_table::borrow(&registry.whitelist, nft_id);

        // Check if the NFT has already been used
        if (status.is_minted) {
            return false
        };

        true
    }

    /// Check if an NFT has been used for minting
    // #[view]
    // public fun has_whitelist(object: Object<ObjectCore>): bool acquires WhitelistNFTRegistry {
    //     if (!exists<WhitelistNFTRegistry>(@presale)) {
    //         return false
    //     };

    //     let registry = borrow_whitelist_nft_registry();
    //     let nft_id = object::object_address(&object);

    //     if (!smart_table::contains(&registry.whitelist, nft_id)) {
    //         return false
    //     };

    //     let status = smart_table::borrow(&registry.whitelist, nft_id);
    //     status.is_minted
    // }

    inline fun borrow_whitelist_nft_registry(): &WhitelistNFTRegistry acquires WhitelistNFTRegistry {
        assert_whitelist_nft_registry_exists();
        borrow_global<WhitelistNFTRegistry>(@presale)
    }

    inline fun borrow_whitelist_nft_registry_mut(): &mut WhitelistNFTRegistry acquires WhitelistNFTRegistry {
        assert_whitelist_nft_registry_exists();
        borrow_global_mut<WhitelistNFTRegistry>(@presale)
    }

    inline fun assert_whitelist_nft_registry_exists() acquires WhitelistNFTRegistry {
        assert!(exists<WhitelistNFTRegistry>(@presale), EWHITELIST_REGISTRY_NOT_EXISTS);
    }

    // === Test Cases ===
    // #[test_only]
    // use aptos_framework::object::create_object_from_account;
    #[test_only]
    use std::string;
    #[test_only]
    use aptos_token_objects::collection;
    #[test_only]
    use aptos_token_objects::token;
    #[test_only]
    use aptos_framework::account::create_account_for_test;

    #[test(deployer = @presale)]
    fun test_add_nft_to_whitelist_ok(deployer: &signer) acquires WhitelistNFTRegistry {
        // Initialize the registry
        init_whitelist_nft_config(deployer);

        // Create dummy NFT object address
        let nft_id = @0xABC;

        // Add NFT to whitelist
        add_nft_to_whitelist(nft_id);

        // Verify the NFT is in the whitelist
        let registry = borrow_whitelist_nft_registry();
        assert!(smart_table::contains(&registry.whitelist, nft_id), 0);

        // Verify the minter is correct
        let status = smart_table::borrow(&registry.whitelist, nft_id);
        // assert!(option::contains(&status.minter, &minter_addr), 0);
        assert!(!status.is_minted, 0);
    }

    #[test(deployer = @presale)]
    #[expected_failure(abort_code = ENFT_ALREADY_WHITELISTED)]
    fun test_add_nft_to_whitelist_duplicate_fails(deployer: &signer) acquires WhitelistNFTRegistry {
        // Initialize the registry
        init_whitelist_nft_config(deployer);

        // Create dummy NFT object address
        let nft_id = @0xABC;
        // let minter_addr = @0x123;

        // Add NFT to whitelist first time
        add_nft_to_whitelist(nft_id);

        // Try to add the same NFT again - should fail
        add_nft_to_whitelist(nft_id);
    }

    #[test(deployer = @presale)]
    fun test_remove_nft_from_whitelist_ok(deployer: &signer) acquires WhitelistNFTRegistry {
        // Initialize the registry
        init_whitelist_nft_config(deployer);

        // Create dummy NFT object address
        let nft_id = @0xABC;
        // let minter_addr = @0x123;

        // Add NFT to whitelist
        add_nft_to_whitelist(nft_id);

        // Verify the NFT is in the whitelist
        {
            let registry = borrow_whitelist_nft_registry();
            assert!(smart_table::contains(&registry.whitelist, nft_id), 0);
        };

        // Remove the NFT from whitelist
        remove_nft_from_whitelist(nft_id);

        // Verify the NFT is no longer in the whitelist
        let registry = borrow_whitelist_nft_registry();
        assert!(!smart_table::contains(&registry.whitelist, nft_id), 0);
    }

    #[test(deployer = @presale)]
    #[expected_failure(abort_code = ENFT_NOT_WHITELISTED)]
    fun test_remove_nonexistent_nft_fails(deployer: &signer) acquires WhitelistNFTRegistry {
        // Initialize the registry
        init_whitelist_nft_config(deployer);

        // Create dummy NFT object address that wasn't added to the whitelist
        let nft_id = @0xABC;

        // Try to remove an NFT that doesn't exist in the whitelist - should fail
        remove_nft_from_whitelist(nft_id);
    }

    #[test_only]
    /// Creates a test token and returns its Object<ObjectCore> and address
    public fun create_test_token_for_testing(creator: &signer): (Object<ObjectCore>, address) {
        // Create a collection for the test tokens
        let collection_name = string::utf8(b"Test Collection");
        let description = string::utf8(b"Test Collection Description");
        let uri = string::utf8(b"https://example.com/collection");
        // let maximum_supply = 0; // Unlimited supply

        // Create the collection
        collection::create_unlimited_collection(
            creator,
            description,
            collection_name,
            option::none(),
            uri
        );

        // Create a token in the collection
        let token_name = string::utf8(b"Test Token");
        let token_description = string::utf8(b"Test Token Description");
        let token_uri = string::utf8(b"https://example.com/token");

        let constructor_ref =
            token::create_from_account(
                creator,
                collection_name,
                token_description,
                token_name,
                option::none(), // royalty
                token_uri
            );

        let token_object = object::object_from_constructor_ref(&constructor_ref);

        let token_addr = object::object_address(&token_object);

        (token_object, token_addr)
    }

    #[test(deployer = @presale, user = @0x456)]
    fun test_mark_nft_as_used_ok(deployer: &signer, user: &signer) acquires WhitelistNFTRegistry {
        // Initialize the registry
        init_whitelist_nft_config(deployer);
        create_account_for_test(signer::address_of(deployer));
        create_account_for_test(signer::address_of(user));

        let (token_object, token_addr) = create_test_token_for_testing(deployer);
        let user_addr = signer::address_of(user);

        object::transfer(deployer, token_object, user_addr);

        // Add NFT to whitelist first
        add_nft_to_whitelist(token_addr);

        // Mark the NFT as used
        mark_nft_as_used(user_addr, token_object);

        // Verify the NFT is marked as used
        let registry = borrow_whitelist_nft_registry();
        let status = smart_table::borrow(&registry.whitelist, token_addr);
        assert!(status.is_minted, 0);
        assert!(option::contains(&status.minter, &user_addr), 0);
    }

    #[test(deployer = @presale, user = @0xAA)]
    #[expected_failure(abort_code = ENFT_NOT_WHITELISTED)]
    fun test_mark_nft_not_in_whitelist_fails(
        deployer: &signer, user: &signer
    ) acquires WhitelistNFTRegistry {
        // Initialize the registry
        init_whitelist_nft_config(deployer);
        create_account_for_test(signer::address_of(deployer));
        create_account_for_test(signer::address_of(user));

        let user_addr = @0x456;
        let (token_object, _token_addr) = create_test_token_for_testing(deployer);

        object::transfer(deployer, token_object, user_addr);

        // Try to mark NFT as used without adding to whitelist first - should fail
        mark_nft_as_used(user_addr, token_object);
    }

    #[test(deployer = @presale, user = @0x456)]
    #[expected_failure(abort_code = ENFT_ALREADY_USED)]
    fun test_mark_already_used_nft_fails(
        deployer: &signer, user: &signer
    ) acquires WhitelistNFTRegistry {
        // Initialize the registry
        init_whitelist_nft_config(deployer);
        create_account_for_test(signer::address_of(deployer));
        create_account_for_test(signer::address_of(user));

        let user_addr = signer::address_of(user);
        let (token_object, token_addr) = create_test_token_for_testing(deployer);
        // Add NFT to whitelist
        add_nft_to_whitelist(token_addr);

        object::transfer(deployer, token_object, user_addr);

        mark_nft_as_used(user_addr, token_object);
        mark_nft_as_used(user_addr, token_object);
    }
}
