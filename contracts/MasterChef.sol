pragma solidity 0.6.12;


import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./AntsToken.sol";


interface IMigratorChef {
    // Perform LP token migration from legacy UniswapV2 to AntsSwap.
    // Take the current LP token address and return the new LP token address.
    // Migrator should have full access to the caller's LP token.
    // Return the new LP token address.
    //
    // XXX Migrator must have allowance access to UniswapV2 LP tokens.
    // AntsSwap must mint EXACTLY the same amount of AntsSwap LP tokens or
    // else something bad will happen. Traditional UniswapV2 does not
    // do that so be careful!
    function migrate(IERC20 token) external returns (IERC20);
}

// MasterChef is the master of Ants. He can make Ants and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once ANTS is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterChef is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using Address for address;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 lockBlock; // lockBlock
        uint256 lockedAmount; // lockedAmount
        uint256 pending; // pending amount, convert to amount via withdraw
        //
        // We do some fancy math here. Basically, any point in time, the amount of ANTSs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accAntsPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accAntsPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;           // Address of LP token contract.
        bool   isSingle;           // sigle token mint
        uint256 allocPoint;       // How many allocation points assigned to this pool. ANTSs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that ANTSs distribution occurs.
        uint256 accAntsPerShare; // Accumulated ANTSs per share, times 1e12. See below.
    }

    // The ANTS TOKEN!
    AntsToken public ants;
    // Dev address.
    address public devaddr;
    // Block number when bonus ANTS period ends.
    uint256 public bonusEndBlock;
    // Token locked block length
    uint256 public halvedBlock;
    uint256 public halvedBlockLength = 2_000_000;
    // Token locked block length
    uint256 public antsLockedBlock;
    // ANTS tokens created per block.
    uint256 public antsPerBlock;
    // Bonus muliplier for early ants makers.
    uint256 public constant BONUS_MULTIPLIER = 5;
    // The migrator contract. It has a lot of power. Can only be set through governance (owner).
    IMigratorChef public migrator;

    // Invite user
    mapping (address => uint256) public balanceInvite;
    mapping (address => address) public userInvite;
    mapping (address => bool) public userInviteAble;
    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Total allocation poitns. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when ANTS mining starts.
    uint256 public startBlock;

    event Invite(address indexed inviter, address indexed invitee);
    event InviteReward(address indexed inviter, address indexed invitee, uint256 amount);

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    constructor(
        AntsToken _ants,
        address _devaddr,
        uint256 _antsPerBlock,
        uint256 _startBlock,
        uint256 _bonusEndBlock
    ) public {
        ants = _ants;
        devaddr = _devaddr;
        antsPerBlock = _antsPerBlock;
        bonusEndBlock = _bonusEndBlock;
        startBlock = _startBlock;
        halvedBlock = _startBlock;
        antsLockedBlock = 200_000;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, IERC20 _lpToken , bool _isSingle, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            isSingle: _isSingle,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accAntsPerShare: 0
        }));
    }

    // Update the given pool's ANTS allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Set the migrator contract. Can only be called by the owner.
    function setMigrator(IMigratorChef _migrator) public onlyOwner {
        migrator = _migrator;
    }

    // Migrate lp token to another lp contract. Can be called by anyone. We trust that migrator contract is good.
    function migrate(uint256 _pid) public {
        require(address(migrator) != address(0), "migrate: no migrator");
        PoolInfo storage pool = poolInfo[_pid];
        IERC20 lpToken = pool.lpToken;
        uint256 bal = lpToken.balanceOf(address(this));
        lpToken.safeApprove(address(migrator), bal);
        IERC20 newLpToken = migrator.migrate(lpToken);
        require(bal == newLpToken.balanceOf(address(this)), "migrate: bad");
        pool.lpToken = newLpToken;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        if (_to <= bonusEndBlock) {
            return _to.sub(_from).mul(BONUS_MULTIPLIER);
        } else if (_from >= bonusEndBlock) {
            return _to.sub(_from);
        } else {
            return bonusEndBlock.sub(_from).mul(BONUS_MULTIPLIER).add(
                _to.sub(bonusEndBlock)
            );
        }
    }

    // View function to see pending ANTSs on frontend.
    function pendingAnts(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accAntsPerShare = pool.accAntsPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));

        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 antsReward = multiplier.mul(antsPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accAntsPerShare = accAntsPerShare.add(antsReward.mul(1e12).div(lpSupply));
        }

        return user.amount.mul(accAntsPerShare).div(1e12).sub(user.rewardDebt);
    }
    // View function to see pending ANTSs on frontend.
    function totalPendingAnts(uint256 _pid, address _user) external view returns (uint256 , uint256 ) {

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accAntsPerShare = pool.accAntsPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 antsReward = multiplier.mul(antsPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accAntsPerShare = accAntsPerShare.add(antsReward.mul(1e12).div(lpSupply));
        }
        uint256 pending =  user.amount.mul(accAntsPerShare).div(1e12).sub(user.rewardDebt).add(user.pending);
        uint256 reward = 0;
        if(userInvite[_user] != address(0) && userInvite[_user] != address(this) ) {
            reward = pending.mul(1).div(20);
        }
        return (pending, reward);
    }

    // Update reward vairables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }

        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 antsReward = multiplier.mul(antsPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        // UserInfo storage dev = userInfo[_pid][devaddr];
        // dev.pending = dev.pending.add(antsReward.div(20));
        ants.mint(devaddr, antsReward.div(20));
        ants.mint(address(this), antsReward);
        pool.accAntsPerShare = pool.accAntsPerShare.add(antsReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;

        if(block.number >= halvedBlockLength.add(halvedBlock)) {
            halvedBlock = block.number;
            antsPerBlock = antsPerBlock.div(2);
        }

    }

    function updateLockBlock(uint256 _pid, uint256 _amount) internal {
        UserInfo storage user = userInfo[_pid][msg.sender];
        if(user.lockBlock == 0) {//
            user.lockBlock = block.number;
        }else {
            // (b-a) * amountB/(amountA + amountbB)
            user.lockBlock =  block.number.sub(user.lockBlock).mul(_amount).div(user.amount.add(_amount)).add(user.lockBlock);
        }
    }

    function setInviter(address _inviter) public {
        require(_inviter != address(0), "Inviter not null");
        require(_inviter != msg.sender, "Inviter cannot be self");
        require(userInviteAble[_inviter], "Inviter invalid");
        userInvite[msg.sender] = _inviter;
    }

    function depositWithInvite(uint256 _pid, uint256 _amount, address _inviter) public {
        if( userInvite[msg.sender] == address(0) ) {
            require(_inviter != address(0), "Inviter not null");
            require(_inviter != msg.sender, "Inviter cannot be self");
            require(userInviteAble[_inviter], "Inviter invalid");
            userInvite[msg.sender] = _inviter;
            emit Invite(_inviter, msg.sender);
        }
        deposit(_pid, _amount);
    }
    // Deposit LP tokens to MasterChef for ANTS allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        if(_amount > 0 &&  !userInviteAble[msg.sender]) {
            userInviteAble[msg.sender] = true;
        }
        if(userInvite[msg.sender] == address(0) ) {
           userInvite[msg.sender] = address(this);
        }
        updateLockBlock(_pid, _amount);
        updatePool(_pid);
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accAntsPerShare).div(1e12).sub(user.rewardDebt);
            // safeAntsTransfer(msg.sender, pending);
            user.pending = user.pending.add(pending);
        }
        if(pool.isSingle) {
            chefSafeTransferFrom(pool.lpToken, address(msg.sender), address(this), _amount);
        }else {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
        }
        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(pool.accAntsPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accAntsPerShare).div(1e12).sub(user.rewardDebt);
        user.pending = user.pending.add(pending);
        //pending ++
        //exec  safeAntsTransfer(msg.sender, pending);
        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accAntsPerShare).div(1e12);
        if(pool.isSingle) {
            chefSafeTransfer(pool.lpToken, address(msg.sender), _amount);
        }else {
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        
        emit Withdraw(msg.sender, _pid, _amount);
    }
    function withdrawInviteReward() public {
        ants.mint(msg.sender, balanceInvite[msg.sender] );
        balanceInvite[msg.sender] = 0;
    }

    function withdrawToken(uint256 _pid) public {
        updatePool(_pid);
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint pending =  user.amount.mul(pool.accAntsPerShare).div(1e12).sub(user.rewardDebt);
        user.pending = pending.add(user.pending);
        user.rewardDebt = user.amount.mul(pool.accAntsPerShare).div(1e12);

        bool invited  = userInvite[msg.sender] != address(0) && userInvite[msg.sender] != address(this);
        uint256 availablePending = invited? user.pending.mul(21).div(20) : user.pending;

        if(user.lockBlock > 0 && block.number.sub(user.lockBlock) < antsLockedBlock ) {
              availablePending =   availablePending.mul(block.number.sub(user.lockBlock)).div(antsLockedBlock);
        }
        if(availablePending > 0 ){
            //update lockedNumber
             //block.number.sub(user.lockBlock).mul(withdrawAmount).div(availablePending).add(user.lockBlock);
            if(invited) {
                //mint invitee reward
                ants.mint(msg.sender, availablePending.mul(1).div(21));
                availablePending = availablePending.mul(20).div(21); // avaliable = avaliable * 1.05
                //record inviter reward
                address inviter = userInvite[msg.sender];
                uint256 reward = availablePending.div(10);
                balanceInvite[inviter] = balanceInvite[inviter].add(reward);
                emit InviteReward(inviter, msg.sender, reward);
            }
            safeAntsTransfer(msg.sender, availablePending);
            user.pending = user.pending.sub(availablePending);
            user.lockBlock = block.number;
        }
        if(user.amount == 0 && user.pending == 0) {
            user.lockBlock = 0;
        }
    }

    function calcuAvalible(uint256 _pid , address _user)  external view returns (uint256 ) {

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accAntsPerShare = pool.accAntsPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 antsReward = multiplier.mul(antsPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accAntsPerShare = accAntsPerShare.add(antsReward.mul(1e12).div(lpSupply));
        }
        uint256 addPending = user.amount.mul(accAntsPerShare).div(1e12).sub(user.rewardDebt);
        uint256 totalPending = user.pending.add(addPending);

        bool invited = userInvite[_user] != address(0) && userInvite[_user] != address(this) ;
        uint256 pending = invited? totalPending.mul(21).div(20) : totalPending;
        if(user.lockBlock > 0  && block.number.sub(user.lockBlock) < antsLockedBlock) {
            return  pending.mul(block.number.sub(user.lockBlock)).div(antsLockedBlock);
        }else {
            return pending;
        }
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        if(pool.isSingle) {
            chefSafeTransfer(pool.lpToken, address(msg.sender), user.amount);
        }else {
            pool.lpToken.safeTransfer(address(msg.sender), user.amount);
        }
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
    }

    // Safe ants transfer function, just in case if rounding error causes pool to not have enough ANTSs.
    function safeAntsTransfer(address _to, uint256 _amount) internal {
        uint256 antsBal = ants.balanceOf(address(this));
        if (_amount > antsBal) {
            ants.transfer(_to, antsBal);
        } else {
            ants.transfer(_to, _amount);
        }
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
    }

    function chefSafeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
    }

    function chefSafeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
    }

    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        // We need to perform a low level call here, to bypass Solidity's return data size checking mechanism, since
        // we're implementing it ourselves. We use {Address.functionCall} to perform this call, which verifies that
        // the target address contains contract code and also asserts for success in the low-level call.

        bytes memory returndata = address(token).functionCall(data, "SafeERC20: low-level call failed");
        if (returndata.length > 0) { // Return data is optional
            // solhint-disable-next-line max-line-length
            require(abi.decode(returndata, (bool)), "SafeERC20: ERC20 operation did not succeed");
        }
    }
}
