#[test_only]
module cove::admin_registry_tests {
    use sui::test_scenario::{Self as ts, Scenario};
    use sui::clock::{Self};
    use cove::admin_registry::{Self, AdminRegistry};

    // === Address Constants ===

    const ADMIN: address = @0xAD;
    const USER1: address = @0x1;
    const USER2: address = @0x2;

    // === Helpers ===

    /// Spin up a scenario, publish the registry from ADMIN, and return the
    /// scenario positioned right after the init transaction.
    fun setup(): Scenario {
        let mut scenario = ts::begin(ADMIN);
        {
            admin_registry::init_for_testing(ts::ctx(&mut scenario));
        };
        scenario
    }

    // -----------------------------------------------------------------------
    // 1. Init creates registry with deployer as super admin
    // -----------------------------------------------------------------------

    #[test]
    fun test_init_creates_registry_with_deployer_as_super_admin() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = ts::take_shared<AdminRegistry>(&scenario);

            // Deployer is the super admin
            assert!(admin_registry::is_super_admin(&registry, ADMIN), 0);
            // Super admin is also considered an admin
            assert!(admin_registry::is_admin(&registry, ADMIN), 1);
            // No regular admins yet
            assert!(admin_registry::admin_count(&registry) == 0, 2);
            // Random address is not an admin
            assert!(!admin_registry::is_admin(&registry, USER1), 3);
            assert!(!admin_registry::is_super_admin(&registry, USER1), 4);

            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // 2. Super admin can add a regular admin
    // -----------------------------------------------------------------------

    #[test]
    fun test_super_admin_can_add_admin() {
        let mut scenario = setup();

        // Transaction 1: ADMIN adds USER1 as a regular admin
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 1000);

            admin_registry::add_admin(
                &mut registry,
                USER1,
                b"user1-label",
                &clock,
                ts::ctx(&mut scenario),
            );

            assert!(admin_registry::is_admin(&registry, USER1), 0);
            assert!(!admin_registry::is_super_admin(&registry, USER1), 1);
            assert!(admin_registry::admin_count(&registry) == 1, 2);

            // Verify admin info
            let (is_admin, added_at, added_by) = admin_registry::get_admin_info(&registry, USER1);
            assert!(is_admin, 3);
            assert!(added_at == 1000, 4);
            assert!(added_by == ADMIN, 5);

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // 3. Cannot add duplicate admin
    // -----------------------------------------------------------------------

    #[test]
    #[expected_failure(abort_code = admin_registry::EAlreadyAdmin)]
    fun test_cannot_add_duplicate_admin() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 1000);

            admin_registry::add_admin(
                &mut registry,
                USER1,
                b"first-add",
                &clock,
                ts::ctx(&mut scenario),
            );

            // Adding the same address again should abort with EAlreadyAdmin
            clock::set_for_testing(&mut clock, 2000);
            admin_registry::add_admin(
                &mut registry,
                USER1,
                b"second-add",
                &clock,
                ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // 4. Cannot add super admin as regular admin
    // -----------------------------------------------------------------------

    #[test]
    #[expected_failure(abort_code = admin_registry::EAlreadyAdmin)]
    fun test_cannot_add_super_admin_as_regular_admin() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 1000);

            // Attempting to add the super admin address as a regular admin
            admin_registry::add_admin(
                &mut registry,
                ADMIN,
                b"super-as-regular",
                &clock,
                ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // 5. Super admin can remove a regular admin
    // -----------------------------------------------------------------------

    #[test]
    fun test_super_admin_can_remove_admin() {
        let mut scenario = setup();

        // Add USER1
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 1000);

            admin_registry::add_admin(
                &mut registry,
                USER1,
                b"user1",
                &clock,
                ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        // Remove USER1
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 2000);

            assert!(admin_registry::is_admin(&registry, USER1), 0);

            admin_registry::remove_admin(
                &mut registry,
                USER1,
                &clock,
                ts::ctx(&mut scenario),
            );

            assert!(!admin_registry::is_admin(&registry, USER1), 1);
            assert!(admin_registry::admin_count(&registry) == 0, 2);

            // get_admin_info should reflect removal
            let (is_admin, _, _) = admin_registry::get_admin_info(&registry, USER1);
            assert!(!is_admin, 3);

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // 6. Cannot remove non-existent admin
    // -----------------------------------------------------------------------

    #[test]
    #[expected_failure(abort_code = admin_registry::ENotAdmin)]
    fun test_cannot_remove_non_existent_admin() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 1000);

            // USER1 was never added -- removing should abort with ENotAdmin
            admin_registry::remove_admin(
                &mut registry,
                USER1,
                &clock,
                ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // 7. Super admin cannot remove themselves via remove_admin
    // -----------------------------------------------------------------------

    #[test]
    #[expected_failure(abort_code = admin_registry::ECannotRemoveSuperAdmin)]
    fun test_super_admin_cannot_remove_self() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 1000);

            admin_registry::remove_admin(
                &mut registry,
                ADMIN,
                &clock,
                ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // 8. Two-step super admin transfer (propose + accept)
    // -----------------------------------------------------------------------

    #[test]
    fun test_two_step_super_admin_transfer() {
        let mut scenario = setup();

        // Step 1: Current super admin proposes USER1
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);

            admin_registry::propose_super_admin(
                &mut registry,
                USER1,
                ts::ctx(&mut scenario),
            );

            // ADMIN is still the super admin until acceptance
            assert!(admin_registry::is_super_admin(&registry, ADMIN), 0);
            assert!(!admin_registry::is_super_admin(&registry, USER1), 1);

            ts::return_shared(registry);
        };

        // Step 2: USER1 accepts the transfer
        ts::next_tx(&mut scenario, USER1);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 3000);

            admin_registry::accept_super_admin(
                &mut registry,
                &clock,
                ts::ctx(&mut scenario),
            );

            // USER1 is now the super admin
            assert!(admin_registry::is_super_admin(&registry, USER1), 2);
            assert!(!admin_registry::is_super_admin(&registry, ADMIN), 3);
            // USER1 is an admin (implicitly as super admin)
            assert!(admin_registry::is_admin(&registry, USER1), 4);
            // ADMIN is no longer an admin at all
            assert!(!admin_registry::is_admin(&registry, ADMIN), 5);

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // 9. Cancel super admin transfer
    // -----------------------------------------------------------------------

    #[test]
    fun test_cancel_super_admin_transfer() {
        let mut scenario = setup();

        // Propose USER1
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);

            admin_registry::propose_super_admin(
                &mut registry,
                USER1,
                ts::ctx(&mut scenario),
            );

            ts::return_shared(registry);
        };

        // Cancel the transfer
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);

            admin_registry::cancel_super_admin_transfer(
                &mut registry,
                ts::ctx(&mut scenario),
            );

            // ADMIN is still the super admin
            assert!(admin_registry::is_super_admin(&registry, ADMIN), 0);

            ts::return_shared(registry);
        };

        // USER1 should not be able to accept after cancellation
        ts::next_tx(&mut scenario, USER1);
        {
            let registry = ts::take_shared<AdminRegistry>(&scenario);

            // Confirm USER1 is not super admin
            assert!(!admin_registry::is_super_admin(&registry, USER1), 1);
            assert!(!admin_registry::is_admin(&registry, USER1), 2);

            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = admin_registry::ENoPendingTransfer)]
    fun test_accept_fails_after_cancel() {
        let mut scenario = setup();

        // Propose then cancel
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);

            admin_registry::propose_super_admin(
                &mut registry,
                USER1,
                ts::ctx(&mut scenario),
            );
            admin_registry::cancel_super_admin_transfer(
                &mut registry,
                ts::ctx(&mut scenario),
            );

            ts::return_shared(registry);
        };

        // USER1 tries to accept -- should fail with ENoPendingTransfer
        ts::next_tx(&mut scenario, USER1);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 5000);

            admin_registry::accept_super_admin(
                &mut registry,
                &clock,
                ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // 10. accept_super_admin removes new super admin from regular admin table
    //     if they were previously a regular admin
    // -----------------------------------------------------------------------

    #[test]
    fun test_accept_super_admin_removes_from_admin_table() {
        let mut scenario = setup();

        // Add USER1 as a regular admin
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 1000);

            admin_registry::add_admin(
                &mut registry,
                USER1,
                b"user1",
                &clock,
                ts::ctx(&mut scenario),
            );

            assert!(admin_registry::admin_count(&registry) == 1, 0);

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        // Propose USER1 as super admin
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);

            admin_registry::propose_super_admin(
                &mut registry,
                USER1,
                ts::ctx(&mut scenario),
            );

            ts::return_shared(registry);
        };

        // USER1 accepts -- should be removed from the regular admin table
        ts::next_tx(&mut scenario, USER1);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 3000);

            admin_registry::accept_super_admin(
                &mut registry,
                &clock,
                ts::ctx(&mut scenario),
            );

            // USER1 is now super admin
            assert!(admin_registry::is_super_admin(&registry, USER1), 1);
            // Admin count should be 0 since USER1 was removed from the table
            assert!(admin_registry::admin_count(&registry) == 0, 2);
            // USER1 is still considered an admin (implicitly as super admin)
            assert!(admin_registry::is_admin(&registry, USER1), 3);

            // get_admin_info should return the super-admin sentinel values
            let (is_admin, added_at, added_by) = admin_registry::get_admin_info(&registry, USER1);
            assert!(is_admin, 4);
            assert!(added_at == 0, 5);
            assert!(added_by == @0x0, 6);

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // 11. Regular admin can renounce
    // -----------------------------------------------------------------------

    #[test]
    fun test_regular_admin_can_renounce() {
        let mut scenario = setup();

        // Add USER1 as admin
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 1000);

            admin_registry::add_admin(
                &mut registry,
                USER1,
                b"user1",
                &clock,
                ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        // USER1 renounces their own admin status
        ts::next_tx(&mut scenario, USER1);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 2000);

            assert!(admin_registry::is_admin(&registry, USER1), 0);

            admin_registry::renounce_admin(
                &mut registry,
                &clock,
                ts::ctx(&mut scenario),
            );

            assert!(!admin_registry::is_admin(&registry, USER1), 1);
            assert!(admin_registry::admin_count(&registry) == 0, 2);

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // 12. Super admin cannot renounce
    // -----------------------------------------------------------------------

    #[test]
    #[expected_failure(abort_code = admin_registry::ECannotRemoveSuperAdmin)]
    fun test_super_admin_cannot_renounce() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 1000);

            admin_registry::renounce_admin(
                &mut registry,
                &clock,
                ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // 13. Non-admin cannot add/remove admins
    // -----------------------------------------------------------------------

    #[test]
    #[expected_failure(abort_code = admin_registry::ENotSuperAdmin)]
    fun test_non_admin_cannot_add_admin() {
        let mut scenario = setup();

        // USER1 (not super admin) tries to add USER2
        ts::next_tx(&mut scenario, USER1);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 1000);

            admin_registry::add_admin(
                &mut registry,
                USER2,
                b"user2",
                &clock,
                ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = admin_registry::ENotSuperAdmin)]
    fun test_non_admin_cannot_remove_admin() {
        let mut scenario = setup();

        // First, add USER1 as admin via ADMIN
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 1000);

            admin_registry::add_admin(
                &mut registry,
                USER1,
                b"user1",
                &clock,
                ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        // USER2 (non-admin) tries to remove USER1
        ts::next_tx(&mut scenario, USER2);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 2000);

            admin_registry::remove_admin(
                &mut registry,
                USER1,
                &clock,
                ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = admin_registry::ENotSuperAdmin)]
    fun test_regular_admin_cannot_add_admin() {
        let mut scenario = setup();

        // Add USER1 as a regular admin
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 1000);

            admin_registry::add_admin(
                &mut registry,
                USER1,
                b"user1",
                &clock,
                ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        // USER1 (regular admin, not super admin) tries to add USER2
        ts::next_tx(&mut scenario, USER1);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 2000);

            admin_registry::add_admin(
                &mut registry,
                USER2,
                b"user2",
                &clock,
                ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = admin_registry::ENotSuperAdmin)]
    fun test_regular_admin_cannot_remove_admin() {
        let mut scenario = setup();

        // Add USER1 and USER2 as regular admins
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 1000);

            admin_registry::add_admin(
                &mut registry,
                USER1,
                b"user1",
                &clock,
                ts::ctx(&mut scenario),
            );
            admin_registry::add_admin(
                &mut registry,
                USER2,
                b"user2",
                &clock,
                ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        // USER1 (regular admin) tries to remove USER2
        ts::next_tx(&mut scenario, USER1);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 2000);

            admin_registry::remove_admin(
                &mut registry,
                USER2,
                &clock,
                ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // 14. is_admin returns true for both super and regular admins
    // -----------------------------------------------------------------------

    #[test]
    fun test_is_admin_returns_true_for_both_tiers() {
        let mut scenario = setup();

        // Add USER1 as regular admin
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 1000);

            admin_registry::add_admin(
                &mut registry,
                USER1,
                b"user1",
                &clock,
                ts::ctx(&mut scenario),
            );

            // Super admin is an admin
            assert!(admin_registry::is_admin(&registry, ADMIN), 0);
            // Regular admin is an admin
            assert!(admin_registry::is_admin(&registry, USER1), 1);
            // Non-admin is not an admin
            assert!(!admin_registry::is_admin(&registry, USER2), 2);

            // Distinguish between the two tiers
            assert!(admin_registry::is_super_admin(&registry, ADMIN), 3);
            assert!(!admin_registry::is_super_admin(&registry, USER1), 4);

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // Additional edge-case tests
    // -----------------------------------------------------------------------

    #[test]
    #[expected_failure(abort_code = admin_registry::ENotSuperAdmin)]
    fun test_non_admin_cannot_propose_super_admin() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, USER1);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);

            admin_registry::propose_super_admin(
                &mut registry,
                USER2,
                ts::ctx(&mut scenario),
            );

            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = admin_registry::ENotSuperAdmin)]
    fun test_wrong_address_cannot_accept_super_admin() {
        let mut scenario = setup();

        // Propose USER1
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);

            admin_registry::propose_super_admin(
                &mut registry,
                USER1,
                ts::ctx(&mut scenario),
            );

            ts::return_shared(registry);
        };

        // USER2 (not the pending super admin) tries to accept
        ts::next_tx(&mut scenario, USER2);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 3000);

            admin_registry::accept_super_admin(
                &mut registry,
                &clock,
                ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = admin_registry::ENoPendingTransfer)]
    fun test_accept_without_proposal_fails() {
        let mut scenario = setup();

        // USER1 tries to accept without any proposal
        ts::next_tx(&mut scenario, USER1);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 1000);

            admin_registry::accept_super_admin(
                &mut registry,
                &clock,
                ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = admin_registry::ENotAdmin)]
    fun test_non_admin_cannot_renounce() {
        let mut scenario = setup();

        // USER1 is not an admin and tries to renounce
        ts::next_tx(&mut scenario, USER1);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 1000);

            admin_registry::renounce_admin(
                &mut registry,
                &clock,
                ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_get_admin_info_for_non_admin() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = ts::take_shared<AdminRegistry>(&scenario);

            let (is_admin, added_at, added_by) = admin_registry::get_admin_info(&registry, USER1);
            assert!(!is_admin, 0);
            assert!(added_at == 0, 1);
            assert!(added_by == @0x0, 2);

            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_get_admin_info_for_super_admin() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = ts::take_shared<AdminRegistry>(&scenario);

            let (is_admin, added_at, added_by) = admin_registry::get_admin_info(&registry, ADMIN);
            assert!(is_admin, 0);
            // Super admin returns sentinel values
            assert!(added_at == 0, 1);
            assert!(added_by == @0x0, 2);

            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_add_and_remove_multiple_admins() {
        let mut scenario = setup();

        // Add two admins
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 1000);

            admin_registry::add_admin(
                &mut registry,
                USER1,
                b"user1",
                &clock,
                ts::ctx(&mut scenario),
            );
            admin_registry::add_admin(
                &mut registry,
                USER2,
                b"user2",
                &clock,
                ts::ctx(&mut scenario),
            );

            assert!(admin_registry::admin_count(&registry) == 2, 0);
            assert!(admin_registry::is_admin(&registry, USER1), 1);
            assert!(admin_registry::is_admin(&registry, USER2), 2);

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        // Remove one admin
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 2000);

            admin_registry::remove_admin(
                &mut registry,
                USER1,
                &clock,
                ts::ctx(&mut scenario),
            );

            assert!(admin_registry::admin_count(&registry) == 1, 3);
            assert!(!admin_registry::is_admin(&registry, USER1), 4);
            assert!(admin_registry::is_admin(&registry, USER2), 5);

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = admin_registry::ENotSuperAdmin)]
    fun test_non_admin_cannot_cancel_transfer() {
        let mut scenario = setup();

        // ADMIN proposes USER1
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);

            admin_registry::propose_super_admin(
                &mut registry,
                USER1,
                ts::ctx(&mut scenario),
            );

            ts::return_shared(registry);
        };

        // USER2 tries to cancel -- should fail
        ts::next_tx(&mut scenario, USER2);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);

            admin_registry::cancel_super_admin_transfer(
                &mut registry,
                ts::ctx(&mut scenario),
            );

            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_new_super_admin_can_manage_admins() {
        let mut scenario = setup();

        // Transfer super admin to USER1
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);

            admin_registry::propose_super_admin(
                &mut registry,
                USER1,
                ts::ctx(&mut scenario),
            );

            ts::return_shared(registry);
        };

        ts::next_tx(&mut scenario, USER1);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 2000);

            admin_registry::accept_super_admin(
                &mut registry,
                &clock,
                ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        // USER1 (new super admin) should be able to add USER2 as admin
        ts::next_tx(&mut scenario, USER1);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 3000);

            admin_registry::add_admin(
                &mut registry,
                USER2,
                b"user2",
                &clock,
                ts::ctx(&mut scenario),
            );

            assert!(admin_registry::is_admin(&registry, USER2), 0);
            assert!(admin_registry::admin_count(&registry) == 1, 1);

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = admin_registry::ENotSuperAdmin)]
    fun test_old_super_admin_cannot_add_after_transfer() {
        let mut scenario = setup();

        // Transfer super admin to USER1
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);

            admin_registry::propose_super_admin(
                &mut registry,
                USER1,
                ts::ctx(&mut scenario),
            );

            ts::return_shared(registry);
        };

        ts::next_tx(&mut scenario, USER1);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 2000);

            admin_registry::accept_super_admin(
                &mut registry,
                &clock,
                ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        // ADMIN (old super admin) tries to add USER2 -- should fail
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 3000);

            admin_registry::add_admin(
                &mut registry,
                USER2,
                b"user2",
                &clock,
                ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    // =======================================================================
    // Orchestrator role -- least-privilege role for the orchestrator. Orchestrators
    // satisfy `is_admin_or_orchestrator` but NOT `is_admin`, and are managed
    // exclusively by the super admin.
    // =======================================================================

    #[test]
    fun test_super_admin_can_add_orchestrator() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 1000);

            admin_registry::add_orchestrator(&mut registry, USER1, &clock, ts::ctx(&mut scenario));

            // USER1 is an orchestrator...
            assert!(admin_registry::is_orchestrator(&registry, USER1), 0);
            // ...and satisfies the orchestrator gate...
            assert!(admin_registry::is_admin_or_orchestrator(&registry, USER1), 1);
            // ...but is NOT an admin or super admin (least privilege).
            assert!(!admin_registry::is_admin(&registry, USER1), 2);
            assert!(!admin_registry::is_super_admin(&registry, USER1), 3);
            assert!(admin_registry::orchestrator_count(&registry) == 1, 4);

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_super_admin_can_remove_orchestrator() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 1000);

            admin_registry::add_orchestrator(&mut registry, USER1, &clock, ts::ctx(&mut scenario));
            assert!(admin_registry::is_orchestrator(&registry, USER1), 0);

            admin_registry::remove_orchestrator(&mut registry, USER1, &clock, ts::ctx(&mut scenario));
            assert!(!admin_registry::is_orchestrator(&registry, USER1), 1);
            assert!(!admin_registry::is_admin_or_orchestrator(&registry, USER1), 2);
            assert!(admin_registry::orchestrator_count(&registry) == 0, 3);

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = admin_registry::EAlreadyOrchestrator)]
    fun test_cannot_add_duplicate_orchestrator() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 1000);

            admin_registry::add_orchestrator(&mut registry, USER1, &clock, ts::ctx(&mut scenario));
            admin_registry::add_orchestrator(&mut registry, USER1, &clock, ts::ctx(&mut scenario));

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = admin_registry::ENotOrchestrator)]
    fun test_cannot_remove_nonexistent_orchestrator() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 1000);

            admin_registry::remove_orchestrator(&mut registry, USER1, &clock, ts::ctx(&mut scenario));

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = admin_registry::ENotSuperAdmin)]
    fun test_regular_admin_cannot_add_orchestrator() {
        let mut scenario = setup();

        // ADMIN grants USER1 regular-admin status.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 1000);
            admin_registry::add_admin(&mut registry, USER1, b"user1", &clock, ts::ctx(&mut scenario));
            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        // A regular admin must NOT be able to add orchestrators -- super admin only.
        ts::next_tx(&mut scenario, USER1);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 2000);
            admin_registry::add_orchestrator(&mut registry, USER2, &clock, ts::ctx(&mut scenario));
            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = admin_registry::ENotSuperAdmin)]
    fun test_non_admin_cannot_add_orchestrator() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, USER1);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 1000);
            admin_registry::add_orchestrator(&mut registry, USER2, &clock, ts::ctx(&mut scenario));
            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_admins_satisfy_is_admin_or_orchestrator_without_being_orchestrators() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 1000);
            admin_registry::add_admin(&mut registry, USER1, b"user1", &clock, ts::ctx(&mut scenario));

            // Super admin and regular admin both pass the orchestrator gate even
            // though neither is in the orchestrator set.
            assert!(admin_registry::is_admin_or_orchestrator(&registry, ADMIN), 0);
            assert!(admin_registry::is_admin_or_orchestrator(&registry, USER1), 1);
            assert!(!admin_registry::is_orchestrator(&registry, ADMIN), 2);
            assert!(!admin_registry::is_orchestrator(&registry, USER1), 3);
            // A complete stranger passes neither gate.
            assert!(!admin_registry::is_admin_or_orchestrator(&registry, USER2), 4);

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_orchestrators_list_and_count() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 1000);

            admin_registry::add_orchestrator(&mut registry, USER1, &clock, ts::ctx(&mut scenario));
            admin_registry::add_orchestrator(&mut registry, USER2, &clock, ts::ctx(&mut scenario));

            assert!(admin_registry::orchestrator_count(&registry) == 2, 0);
            let ops = admin_registry::orchestrators(&registry);
            assert!(ops.length() == 2, 1);
            assert!(ops.contains(&USER1), 2);
            assert!(ops.contains(&USER2), 3);

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_orchestrator_can_also_be_super_admin_independently() {
        // The orchestrator set is independent of admin status: the super admin can
        // be added as an orchestrator too (the roles don't conflict). This keeps the
        // gate logic simple -- is_admin_or_orchestrator is just an OR.
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 1000);

            admin_registry::add_orchestrator(&mut registry, ADMIN, &clock, ts::ctx(&mut scenario));
            assert!(admin_registry::is_orchestrator(&registry, ADMIN), 0);
            assert!(admin_registry::is_super_admin(&registry, ADMIN), 1);
            assert!(admin_registry::is_admin_or_orchestrator(&registry, ADMIN), 2);

            clock::destroy_for_testing(clock);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }
}
