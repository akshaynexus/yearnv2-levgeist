pragma solidity 0.6.12;

interface IMultiFeeDistribution {
    function addReward(address _rewardsToken) external;

    //   function claimableRewards ( address account ) external view returns ( tuple[] rewards );
    //   function earnedBalances ( address user ) external view returns ( uint256 total, tuple[] earningsData );
    function exit() external;

    function getReward() external;

    function getRewardForDuration(address _rewardsToken) external view returns (uint256);

    function lastTimeRewardApplicable(address _rewardsToken) external view returns (uint256);

    function lockDuration() external view returns (uint256);

    //   function lockedBalances ( address user ) external view returns ( uint256 total, uint256 unlockable, uint256 locked, tuple[] lockData );
    function lockedSupply() external view returns (uint256);

    function mint(
        address user,
        uint256 amount,
        bool withPenalty
    ) external;

    function minters(address) external view returns (bool);

    function mintersAreSet() external view returns (bool);

    function owner() external view returns (address);

    function recoverERC20(address tokenAddress, uint256 tokenAmount) external;

    function renounceOwnership() external;

    function rewardData(address)
        external
        view
        returns (
            uint256 periodFinish,
            uint256 rewardRate,
            uint256 lastUpdateTime,
            uint256 rewardPerTokenStored,
            uint256 balance
        );

    function rewardPerToken(address _rewardsToken) external view returns (uint256);

    function rewardTokens(uint256) external view returns (address);

    function rewards(address, address) external view returns (uint256);

    function rewardsDuration() external view returns (uint256);

    function setMinters(address[] memory _minters) external;

    function stake(uint256 amount, bool lock) external;

    function stakingToken() external view returns (address);

    function totalBalance(address user) external view returns (uint256 amount);

    function totalSupply() external view returns (uint256);

    function transferOwnership(address newOwner) external;

    function unlockedBalance(address user) external view returns (uint256 amount);

    function userRewardPerTokenPaid(address, address) external view returns (uint256);

    function withdraw(uint256 amount) external;

    function withdrawExpiredLocks() external;

    function withdrawableBalance(address user) external view returns (uint256 amount, uint256 penaltyAmount);
}
