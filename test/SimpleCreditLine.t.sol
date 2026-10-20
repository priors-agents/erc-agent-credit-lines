// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IAgentCreditLine} from "../src/IAgentCreditLine.sol";
import {SimpleCreditLine} from "../src/SimpleCreditLine.sol";
import {MockRegistry, MockToken} from "./mocks/Mocks.sol";

contract SimpleCreditLineTest is Test {
    event Borrowed(
        uint256 indexed loanId,
        uint256 indexed agentId,
        address indexed to,
        uint256 principal,
        uint256 fee,
        uint64 dueAt
    );
    event Repaid(
        uint256 indexed loanId, uint256 indexed agentId, address indexed payer, uint256 principal, uint256 fee
    );
    event Defaulted(uint256 indexed loanId, uint256 indexed agentId, address indexed owner, uint256 principal);

    uint256 constant AGENT = 6197;
    uint64 constant GRACE = 3 days;
    uint64 constant MAX_TERM = 30 days;
    uint16 constant FEE_BPS = 100; // 1% per 30 days

    MockRegistry registry;
    MockToken usd;
    SimpleCreditLine lender;
    address admin = makeAddr("admin");
    address owner = makeAddr("owner");
    address wallet = makeAddr("wallet");
    address stranger = makeAddr("stranger");

    function setUp() public {
        registry = new MockRegistry();
        usd = new MockToken();
        lender = new SimpleCreditLine(address(registry), address(usd), GRACE, MAX_TERM, admin);
        registry.mint(owner, AGENT);
        usd.mint(address(lender), 1_000e6);
        vm.prank(admin);
        lender.setLine(AGENT, 50e6, FEE_BPS);
    }

    function _borrow(uint256 amount, uint64 term) internal returns (uint256) {
        vm.prank(owner);
        return lender.borrow(AGENT, amount, term, wallet, type(uint256).max);
    }

    // ------------------------------------------------------------- views

    function test_identityRegistryAndAsset() public view {
        assertEq(lender.identityRegistry(), address(registry));
        assertEq(lender.asset(), address(usd));
    }

    function test_supportsInterface() public view {
        assertTrue(lender.supportsInterface(type(IAgentCreditLine).interfaceId));
        assertTrue(lender.supportsInterface(0x01ffc9a7)); // ERC-165
        assertFalse(lender.supportsInterface(0xffffffff));
    }

    function test_availableCredit_isLineMinusOutstanding_andCappedByCash() public {
        assertEq(lender.availableCredit(AGENT), 50e6);
        _borrow(20e6, 7 days);
        assertEq(lender.availableCredit(AGENT), 30e6);
        vm.prank(admin);
        lender.setLine(AGENT, 5_000e6, FEE_BPS);
        assertEq(lender.availableCredit(AGENT), 980e6); // the cash left, not the line
        assertEq(lender.availableCredit(42), 0); // no line, no revert
    }

    // ------------------------------------------------------------- borrow

    function test_borrow_paysTo_recordsLoan_emitsBorrowed() public {
        uint64 term = 7 days;
        uint256 fee = lender.quote(AGENT, 10e6, term);
        // 10 USDG at 1% per 30 days for 7 days: 10e6 * 100 * 604800 / (10000 * 2592000) = 23333.33, rounded up
        assertEq(fee, 23_334);
        vm.expectEmit(true, true, true, true);
        emit Borrowed(1, AGENT, wallet, 10e6, fee, uint64(block.timestamp) + term);
        uint256 loanId = _borrow(10e6, term);

        assertEq(loanId, 1);
        assertEq(usd.balanceOf(wallet), 10e6);
        IAgentCreditLine.LoanInfo memory l = lender.loanInfo(loanId);
        assertEq(l.agentId, AGENT);
        assertEq(l.owner, owner);
        assertEq(l.principal, 10e6);
        assertEq(l.fee, fee);
        assertEq(l.dueAt, uint64(block.timestamp) + term);
        assertEq(l.defaultableAt, l.dueAt + GRACE);
        assertEq(uint8(l.status), uint8(IAgentCreditLine.LoanStatus.Active));
        assertEq(lender.amountDue(loanId), 10e6 + fee);
    }

    function test_borrow_byStranger_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(SimpleCreditLine.NotController.selector);
        lender.borrow(AGENT, 1e6, 7 days, stranger, type(uint256).max);
    }

    function test_borrow_aboveAvailable_reverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SimpleCreditLine.OverCredit.selector, 50e6));
        lender.borrow(AGENT, 50e6 + 1, 7 days, wallet, type(uint256).max);
    }

    function test_borrow_feeAboveMaxFee_reverts() public {
        uint256 fee = lender.quote(AGENT, 10e6, 7 days);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SimpleCreditLine.FeeAboveMax.selector, fee));
        lender.borrow(AGENT, 10e6, 7 days, wallet, fee - 1);
    }

    function test_borrow_badTerm_reverts() public {
        vm.startPrank(owner);
        vm.expectRevert(SimpleCreditLine.BadTerm.selector);
        lender.borrow(AGENT, 1e6, 0, wallet, type(uint256).max);
        vm.expectRevert(SimpleCreditLine.BadTerm.selector);
        lender.borrow(AGENT, 1e6, MAX_TERM + 1, wallet, type(uint256).max);
        vm.stopPrank();
    }

    function testFuzz_quoteEqualsFeeCharged(uint256 amount, uint64 term) public {
        amount = bound(amount, 1, 50e6);
        term = uint64(bound(term, 1, MAX_TERM));
        uint256 quoted = lender.quote(AGENT, amount, term);
        uint256 loanId = _borrow(amount, term);
        assertEq(lender.loanInfo(loanId).fee, quoted);
    }

    function test_loanIds_areUniqueAndNeverZero() public {
        uint256 a = _borrow(1e6, 7 days);
        uint256 b = _borrow(1e6, 7 days);
        assertGt(a, 0);
        assertEq(b, a + 1);
    }

    // ------------------------------------------------------------- repay

    function test_repay_byAnyone_closesLoan_emitsRepaid() public {
        uint256 loanId = _borrow(10e6, 7 days);
        uint256 due = lender.amountDue(loanId);
        usd.mint(stranger, due);
        vm.startPrank(stranger);
        usd.approve(address(lender), due);
        vm.expectEmit(true, true, true, true);
        emit Repaid(loanId, AGENT, stranger, 10e6, due - 10e6);
        uint256 paid = lender.repay(loanId, due);
        vm.stopPrank();

        assertEq(paid, due);
        assertEq(usd.balanceOf(stranger), 0);
        assertEq(lender.amountDue(loanId), 0);
        assertEq(uint8(lender.loanInfo(loanId).status), uint8(IAgentCreditLine.LoanStatus.Repaid));
        assertEq(lender.availableCredit(AGENT), 50e6);
    }

    function test_repay_dueAboveMaxDue_reverts() public {
        uint256 loanId = _borrow(10e6, 7 days);
        uint256 due = lender.amountDue(loanId);
        vm.expectRevert(abi.encodeWithSelector(SimpleCreditLine.DueAboveMax.selector, due));
        lender.repay(loanId, due - 1);
    }

    function test_repay_twice_reverts() public {
        uint256 loanId = _borrow(1e6, 7 days);
        uint256 due = lender.amountDue(loanId);
        usd.mint(address(this), 2 * due);
        usd.approve(address(lender), 2 * due);
        lender.repay(loanId, due);
        vm.expectRevert(SimpleCreditLine.NotActive.selector);
        lender.repay(loanId, due);
    }

    // ------------------------------------------------------------- default

    function test_markDefault_beforeDefaultableAt_reverts() public {
        uint256 loanId = _borrow(10e6, 7 days);
        uint64 at = lender.loanInfo(loanId).defaultableAt;
        vm.warp(at - 1);
        vm.expectRevert(abi.encodeWithSelector(SimpleCreditLine.NotDefaultable.selector, at));
        lender.markDefault(loanId);
    }

    function test_markDefault_marksTheOwnerAtBorrow_evenAfterATransfer() public {
        uint256 loanId = _borrow(10e6, 7 days);
        vm.prank(owner);
        registry.transfer(AGENT, stranger); // sold after drawing
        vm.warp(lender.loanInfo(loanId).defaultableAt);
        vm.expectEmit(true, true, true, true);
        emit Defaulted(loanId, AGENT, owner, 10e6);
        lender.markDefault(loanId);

        assertEq(uint8(lender.loanInfo(loanId).status), uint8(IAgentCreditLine.LoanStatus.Defaulted));
        assertEq(lender.amountDue(loanId), 0);
        assertEq(lender.availableCredit(AGENT), 0); // no new credit after a default
    }

    // ------------------------------------------------------------- controllers

    function test_delegate_canBorrow_andLapsesWhenTheAgentChangesHands() public {
        address key = makeAddr("key");
        vm.prank(owner);
        lender.setDelegate(AGENT, key);
        assertTrue(lender.isController(AGENT, key));

        vm.prank(key);
        lender.borrow(AGENT, 1e6, 7 days, key, type(uint256).max);

        vm.prank(owner);
        registry.transfer(AGENT, stranger);
        assertFalse(lender.isController(AGENT, key));
        assertTrue(lender.isController(AGENT, stranger));
        vm.prank(key);
        vm.expectRevert(SimpleCreditLine.NotController.selector);
        lender.borrow(AGENT, 1e6, 7 days, key, type(uint256).max);
    }

    function test_isController_falseForZeroAndUnknownAgents() public view {
        assertFalse(lender.isController(AGENT, address(0)));
        assertFalse(lender.isController(999, owner));
    }
}
