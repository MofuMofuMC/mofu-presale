module bridge::bridge_config {
    use std::signer;
    use std::error;

    friend bridge::bridge;
    // ======== Errors ========

    const ECONFIG_NOT_EXISTS: u64 = 1;
    const ENOT_AUTHORIZED: u64 = 1;

    // ========== Constants ========
    // ========== Events ========
    // ========== Structs ========

    struct BridgeConfig has key {
        admin: address,
        enabled: bool
    }

    // ======== Public Package Functions ========

    public(friend) fun init_config(owner: &signer, admin: address) {
        let config = BridgeConfig { admin, enabled: true };
        move_to(owner, config);
    }

    public fun is_enabled(): bool acquires BridgeConfig {
        assert_config_present();
        let config = borrow_global<BridgeConfig>(@bridge);
        return config.enabled
    }

    public(friend) fun set_enabled(sender: &signer, enabled: bool) acquires BridgeConfig {
        assert_config_present();
        let config = borrow_global_mut<BridgeConfig>(@bridge);
        let addr = signer::address_of(sender);
        assert!(
            is_admin(config, addr),
            error::permission_denied(ENOT_AUTHORIZED) // code 196621
        );
        config.enabled = enabled;
    }

    public(friend) fun assert_is_admin(sender: &signer) acquires BridgeConfig {
        assert_config_present();
        let config = borrow_global<BridgeConfig>(@bridge);
        let addr = signer::address_of(sender);
        assert!(
            is_admin(config, addr),
            error::permission_denied(ENOT_AUTHORIZED) // code 196621
        );
    }

    // ======== Private Functions ========

    inline fun is_admin(config: &BridgeConfig, addr: address): bool {
        if (config.admin == addr) { true }
        else { false }
    }

    inline fun assert_config_present() {
        assert!(exists<BridgeConfig>(@bridge), ECONFIG_NOT_EXISTS);
    }

    // ======== Views ========

    #[view]
    public fun get_admin(): address acquires BridgeConfig {
        assert_config_present();
        let config = borrow_global<BridgeConfig>(@bridge);
        return config.admin
    }

    // ======== Tests ========

    #[test(sender = @bridge)]
    public fun test_init_config(sender: &signer) acquires BridgeConfig {
        let admin = signer::address_of(sender);
        init_config(sender, admin);
        assert_is_admin(sender);
    }
}
