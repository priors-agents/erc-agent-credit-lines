// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {IAgentCreditLine} from "./IAgentCreditLine.sol";

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IERC721OwnerOf {
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

/// @title SimpleCreditLine
/// @notice Reference implementation of the Agent Credit Lines draft. One admin sets each agent's line and fee rate; the
///         contract's own balance of the asset is its liquidity. Fees are pro rata: `feeBps` per 30 days of term,
///         rounded up. A delegate is bound to the owner who named it and lapses while anyone else holds the agent.
/// @dev Not audited. A reference for the interface, not a lender to deploy with real money.
contract SimpleCreditLine is IAgentCreditLine, IERC165 {
    uint256 private constant BPS = 10_000;
    uint256 private constant FEE_PERIOD = 30 days;

    struct Line {
        uint256 limit;
        uint256 outstanding; // principal of the agent's active loans
        uint16 feeBps;
    }

    struct Delegation {
        address delegate;
        address namedBy;
    }

    IERC721OwnerOf private immutable _registry;
    IERC20Minimal private immutable _asset;
    uint64 public immutable grace;
    uint64 public immutable maxTerm;
    address public immutable admin;

    mapping(uint256 => Line) public lines;
    mapping(uint256 => Delegation) private _delegations;
    mapping(uint256 => LoanInfo) private _loans;
    uint256 public loanCount;

    event LineSet(uint256 indexed agentId, uint256 limit, uint16 feeBps);
    event DelegateSet(uint256 indexed agentId, address indexed owner, address delegate);

    error NotAdmin();
    error NotOwner();
    error NotController();
    error ZeroAmount();
    error BadTerm();
    error OverCredit(uint256 available);
    error FeeAboveMax(uint256 fee);
    error DueAboveMax(uint256 due);
    error NotActive();
    error NotDefaultable(uint64 defaultableAt);
    error TransferFailed();

    constructor(address registry_, address asset_, uint64 grace_, uint64 maxTerm_, address admin_) {
        _registry = IERC721OwnerOf(registry_);
        _asset = IERC20Minimal(asset_);
        grace = grace_;
        maxTerm = maxTerm_;
        admin = admin_;
    }

    // ---------------------------------------------------------------- admin and owner

    function setLine(uint256 agentId, uint256 limit, uint16 feeBps) external {
        if (msg.sender != admin) revert NotAdmin();
        lines[agentId].limit = limit;
        lines[agentId].feeBps = feeBps;
        emit LineSet(agentId, limit, feeBps);
    }

    /// @notice The agent's owner names a key that may borrow for it. The key lapses while another address holds the
    ///         agent. It acts again if the agent returns to the same owner: a registry with a transfer nonce
    ///         (ERC-5008) lets an implementation bind the key to that nonce instead.
    function setDelegate(uint256 agentId, address delegate) external {
        address owner = _registry.ownerOf(agentId);
        if (owner != msg.sender) revert NotOwner();
        _delegations[agentId] = Delegation(delegate, owner);
        emit DelegateSet(agentId, owner, delegate);
    }

    // ---------------------------------------------------------------- IAgentCreditLine views

    function identityRegistry() external view returns (address) {
        return address(_registry);
    }

    function asset() external view returns (address) {
        return address(_asset);
    }

    function isController(uint256 agentId, address account) public view returns (bool) {
        if (account == address(0)) return false;
        address owner;
        try _registry.ownerOf(agentId) returns (address o) {
            owner = o;
        } catch {
            return false;
        }
        if (account == owner) return true;
        Delegation memory d = _delegations[agentId];
        return d.delegate == account && d.namedBy == owner;
    }

    function availableCredit(uint256 agentId) public view returns (uint256) {
        Line memory l = lines[agentId];
        uint256 room = l.limit > l.outstanding ? l.limit - l.outstanding : 0;
        uint256 cash = _asset.balanceOf(address(this));
        return room < cash ? room : cash;
    }

    function quote(uint256 agentId, uint256 amount, uint64 term) public view returns (uint256) {
        uint256 num = amount * lines[agentId].feeBps * term;
        uint256 den = BPS * FEE_PERIOD;
        return (num + den - 1) / den;
    }

    function amountDue(uint256 loanId) public view returns (uint256) {
        LoanInfo storage loan = _loans[loanId];
        if (loan.status != LoanStatus.Active) return 0;
        return loan.principal + loan.fee;
    }

    function loanInfo(uint256 loanId) external view returns (LoanInfo memory) {
        return _loans[loanId];
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IAgentCreditLine).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    // ---------------------------------------------------------------- IAgentCreditLine actions

    function borrow(uint256 agentId, uint256 amount, uint64 term, address to, uint256 maxFee)
        external
        returns (uint256 loanId)
    {
        if (!isController(agentId, msg.sender)) revert NotController();
        if (amount == 0) revert ZeroAmount();
        if (term == 0 || term > maxTerm) revert BadTerm();
        uint256 available = availableCredit(agentId);
        if (amount > available) revert OverCredit(available);
        uint256 fee = quote(agentId, amount, term);
        if (fee > maxFee) revert FeeAboveMax(fee);

        loanId = ++loanCount;
        uint64 dueAt = uint64(block.timestamp) + term;
        _loans[loanId] = LoanInfo({
            agentId: agentId,
            owner: _registry.ownerOf(agentId),
            principal: amount,
            fee: fee,
            issuedAt: uint64(block.timestamp),
            dueAt: dueAt,
            defaultableAt: dueAt + grace,
            status: LoanStatus.Active
        });
        lines[agentId].outstanding += amount;

        emit Borrowed(loanId, agentId, to, amount, fee, dueAt);
        if (!_asset.transfer(to, amount)) revert TransferFailed();
    }

    function repay(uint256 loanId, uint256 maxDue) external returns (uint256 paid) {
        LoanInfo storage loan = _loans[loanId];
        if (loan.status != LoanStatus.Active) revert NotActive();
        paid = loan.principal + loan.fee;
        if (paid > maxDue) revert DueAboveMax(paid);

        loan.status = LoanStatus.Repaid;
        lines[loan.agentId].outstanding -= loan.principal;

        emit Repaid(loanId, loan.agentId, msg.sender, loan.principal, loan.fee);
        if (!_asset.transferFrom(msg.sender, address(this), paid)) revert TransferFailed();
    }

    function markDefault(uint256 loanId) external {
        LoanInfo storage loan = _loans[loanId];
        if (loan.status != LoanStatus.Active) revert NotActive();
        if (block.timestamp < loan.defaultableAt) revert NotDefaultable(loan.defaultableAt);

        loan.status = LoanStatus.Defaulted;
        Line storage line = lines[loan.agentId];
        line.outstanding -= loan.principal;
        line.limit = 0; // a defaulted agent gets no new credit here

        emit Defaulted(loanId, loan.agentId, loan.owner, loan.principal);
    }
}
