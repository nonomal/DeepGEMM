#pragma once

#include <deep_gemm/common/types.hpp>
#include <deep_gemm/common/utils.cuh>

namespace deep_gemm {

enum class KGroupedIndexType {
    MN,
    K,
    SF_K,
};

#pragma clang diagnostic push
#pragma ide diagnostic ignored "cppcoreguidelines-pro-type-member-init"
template <GemmType kGemmType,
          uint32_t BLOCK_M, uint32_t BLOCK_N,
          uint32_t kNumGroups,
          uint32_t kNumMulticast, bool kIsMulticastOnA,
          // TODO: refactor this by other values
          uint32_t kNum1DBlocksPerGroup = 16>
struct Scheduler {
    int current_iter = -1;

    // Block configs
    uint32_t num_blocks;
    uint32_t num_m_blocks;
    uint32_t num_n_blocks;

    // For SM90 multicast checks
    uint32_t num_blocks_in_group;
    bool is_peer_cta_alive = true;

    // For grouped GEMM
    int* grouped_layout;
    uint32_t current_group_idx;
    // Only used for masked layout
    uint32_t current_m_cumsum;
    // Only used for k-grouped layout
    uint32_t current_shape_k, current_num_valid_groups, current_k_cumsum, current_sf_k_cumsum;

    // ReSharper disable once CppPossiblyUninitializedMember
    __device__ __forceinline__ explicit Scheduler(const uint32_t& shape_m, const uint32_t& shape_n,
                                                  int* grouped_layout = nullptr) {
        num_m_blocks = ceil_div(shape_m, BLOCK_M);
        num_n_blocks = ceil_div(shape_n, BLOCK_N);
        if constexpr (kGemmType == GemmType::Normal) {
            num_blocks = num_m_blocks * num_n_blocks;
        } else if (kGemmType == GemmType::MGroupedContiguous) {
            num_blocks = num_m_blocks * num_n_blocks;
            this->grouped_layout = grouped_layout;
        } else if (kGemmType == GemmType::MGroupedMasked) {
            current_group_idx = current_m_cumsum = 0;
            this->grouped_layout = grouped_layout;
        } else if (kGemmType == GemmType::KGroupedContiguous) {
            current_group_idx = current_num_valid_groups = 0;
            current_k_cumsum = current_sf_k_cumsum = 0;
            current_shape_k = __ldg(grouped_layout + current_group_idx);
            this->grouped_layout = grouped_layout;
        }
    }

    __device__ __forceinline__ void get_swizzled_block_idx(const uint32_t& block_idx, uint32_t& m_block_idx, uint32_t& n_block_idx) {
        DG_STATIC_ASSERT(kNum1DBlocksPerGroup % kNumMulticast == 0, "Invalid group size");

        // Swizzle for better L2 usages
        const auto& primary_num_blocks = kIsMulticastOnA ? num_n_blocks : num_m_blocks;
        const auto& secondary_num_blocks = kIsMulticastOnA ? num_m_blocks : num_n_blocks;
        const auto& num_blocks_per_group = secondary_num_blocks * kNum1DBlocksPerGroup;
        const auto& group_idx = block_idx / num_blocks_per_group;
        auto first_block_idx = group_idx * kNum1DBlocksPerGroup;
        auto in_group_idx = block_idx % num_blocks_per_group;
        num_blocks_in_group = min(kNum1DBlocksPerGroup, primary_num_blocks - first_block_idx);

        // Fix unaligned TMA multicast
        // NOTES: for SM90 only, as SM90 can dynamically disable TMA multicast
        // while SM100 uses 2-CTA, which can not be dynamically disabled
#if __CUDA_ARCH__ < 1000
        if (kNumMulticast > 1 and num_blocks_in_group % 2 != 0) {
            if (in_group_idx < (num_blocks_in_group ^ 1) * secondary_num_blocks) {
                num_blocks_in_group = num_blocks_in_group ^ 1;
            } else {
                in_group_idx = in_group_idx - (num_blocks_in_group ^ 1) * secondary_num_blocks;
                first_block_idx += num_blocks_in_group ^ 1;
                num_blocks_in_group = 1;
            }
        }
#endif

        // Convert to final M/N block indices
        if constexpr (kIsMulticastOnA) {
            m_block_idx = in_group_idx / num_blocks_in_group;
            n_block_idx = first_block_idx + in_group_idx % num_blocks_in_group;
        } else {
            m_block_idx = first_block_idx + in_group_idx % num_blocks_in_group;
            n_block_idx = in_group_idx / num_blocks_in_group;
        }
    }

    template <bool kWithGroupOffset, KGroupedIndexType kIndexType = KGroupedIndexType::MN>
    __device__ __forceinline__ uint32_t get_global_idx(const uint32_t shape_dim, const uint32_t block_size,
                                                       const uint32_t& block_idx, const uint32_t& m_block_idx = 0) {
        if constexpr (kGemmType == GemmType::Normal) {
            return block_idx * block_size;
        } else if constexpr (kGemmType == GemmType::MGroupedContiguous) {
            const auto offset = kWithGroupOffset ? std::max(0, __ldg(grouped_layout + m_block_idx * BLOCK_M)) : 0;
            return offset * shape_dim + block_idx * block_size;
        } else if constexpr (kGemmType == GemmType::MGroupedMasked) {
            const auto offset = kWithGroupOffset ? current_group_idx : 0;
            return offset * shape_dim + block_idx * block_size;
        } else if constexpr (kGemmType == GemmType::KGroupedContiguous) {
            auto offset = 0;
            if constexpr (kWithGroupOffset) {
                if constexpr (kIndexType == KGroupedIndexType::MN)
                    offset = current_group_idx * shape_dim;
                else if constexpr (kIndexType == KGroupedIndexType::K)
                    offset = current_k_cumsum;
                else if constexpr (kIndexType == KGroupedIndexType::SF_K)
                    offset = current_sf_k_cumsum;
            }
            return offset + block_idx * block_size;
        }
    }

    __device__ __forceinline__ bool get_next_block(uint32_t& m_block_idx, uint32_t& n_block_idx) {
        const auto next_block_idx = (++ current_iter) * gridDim.x + blockIdx.x;

        if constexpr (kGemmType == GemmType::MGroupedMasked) {
            while (true) {
                // End of the task
                if (current_group_idx == kNumGroups)
                    return false;

                // Within current group
                num_m_blocks = ceil_div(static_cast<uint32_t>(__ldg(grouped_layout + current_group_idx)), BLOCK_M);
                const auto current_m_block_cumsum = current_m_cumsum + num_m_blocks;
                if (next_block_idx < current_m_block_cumsum * num_n_blocks)
                    break;

                // Move to check the next group
                current_group_idx ++, current_m_cumsum = current_m_block_cumsum;
            }

            get_swizzled_block_idx(next_block_idx - current_m_cumsum * num_n_blocks, m_block_idx, n_block_idx);
        } else if (kGemmType == GemmType::KGroupedContiguous) {
            while (true) {
                // End of the task
                if (current_group_idx == kNumGroups)
                    return false;

                // Within current group
                if (current_shape_k > 0 and next_block_idx < (current_num_valid_groups + 1) * num_m_blocks * num_n_blocks)
                    break;

                // Move to check the next group
                if (current_shape_k > 0) {
                    current_k_cumsum += current_shape_k;
                    current_sf_k_cumsum += ceil_div(current_shape_k, 512u);
                    current_num_valid_groups ++;
                }
                if ((++ current_group_idx) != kNumGroups)
                    current_shape_k = __ldg(grouped_layout + current_group_idx);
            }

            get_swizzled_block_idx(next_block_idx - current_num_valid_groups * num_m_blocks * num_n_blocks, m_block_idx, n_block_idx);
        } else {
            if (next_block_idx >= num_blocks)
                return false;

            // For SM90 only
            // NOTES: we don't have to set `is_peer_cta_alive` for masked grouped GEMM, as it must be aligned
            is_peer_cta_alive = num_n_blocks % kNumMulticast == 0 or                  // Always aligned on N (constant bypass)
                                num_m_blocks % kNumMulticast == 0 or                  // Always aligned on M (constant bypass)
                                (next_block_idx ^ 1) < num_blocks;                    // Peer CTA in bound
            get_swizzled_block_idx(next_block_idx, m_block_idx, n_block_idx);
        }
        return true;
    }

    // For SM90 only
    __device__ __forceinline__ bool is_tma_multicast_valid(const uint32_t& m_block_idx) const {
        if (num_blocks_in_group == 1)
            return false;
        if constexpr (kGemmType == GemmType::Normal or kGemmType == GemmType::MGroupedMasked) {
            return true;
        } else {
            DG_STATIC_ASSERT(kGemmType == GemmType::MGroupedContiguous, "Invalid Gemm type");
            if constexpr (kIsMulticastOnA) {
                return true;
            } else {
                const auto& group_idx = __ldg(grouped_layout + m_block_idx * BLOCK_M);
                const auto& peer_group_idx = __ldg(grouped_layout + (m_block_idx ^ 1) * BLOCK_M);
                return group_idx == peer_group_idx;
            }
        }
    }

    // For SM90 only
    // ReSharper disable once CppNotAllPathsReturnValue
    __device__ __forceinline__ bool is_computation_valid(const uint32_t& m_block_idx, const uint32_t& m_offset) const {
        if constexpr (kGemmType == GemmType::Normal) {
            return true;
        } else if constexpr (kGemmType == GemmType::MGroupedContiguous) {
            return __ldg(grouped_layout + m_offset + m_block_idx * BLOCK_M) >= 0;
        } else if constexpr (kGemmType == GemmType::MGroupedMasked) {
            return m_offset + m_block_idx * BLOCK_M < __ldg(grouped_layout + current_group_idx);
        }
    }
};

#pragma clang diagnostic pop

} // namespace deep_gemm
