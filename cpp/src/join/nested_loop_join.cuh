/*
 * Copyright (c) 2020, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#pragma once

#include <cudf/detail/utilities/cuda.cuh>
#include <cudf/scalar/scalar.hpp>
#include <cudf/scalar/scalar_device_view.cuh>
#include <cudf/table/table.hpp>
#include <cudf/table/table_device_view.cuh>
#include <cudf/table/table_view.hpp>
#include <iostream>

#include <join/hash_join.cuh>
#include <join/join_common_utils.hpp>
#include <join/join_kernels.cuh>

namespace cudf {
namespace detail {
/* --------------------------------------------------------------------------*/
/**
 * @brief  Gives an estimate of the size of the join output produced when
 * joining two tables together.
 *
 * @throw cudf::logic_error if JoinKind is not INNER_JOIN or LEFT_JOIN
 *
 * @param left The left hand table
 * @param right The right hand table
 *
 * @returns An estimate of the size of the output of the join operation
 */
/* ----------------------------------------------------------------------------*/
template <join_kind JoinKind>
size_type estimate_nested_loop_join_output_size(table_device_view left,
                                                table_device_view right,
                                                cudaStream_t stream)
{
  const size_type left_num_rows{left.num_rows()};
  const size_type right_num_rows{right.num_rows()};

  if (right_num_rows == 0) {
    // If the right table is empty, we know exactly how large the output
    // will be for the different types of joins and can return immediately
    switch (JoinKind) {
      // Inner join with an empty table will have no output
      case join_kind::INNER_JOIN: return 0;

      // Left join with an empty table will have an output of NULL rows
      // equal to the number of rows in the left table
      case join_kind::LEFT_JOIN: return left_num_rows;

      default: CUDF_FAIL("Unsupported join type");
    }
  }

  // Allocate storage for the counter used to get the size of the join output
  size_type h_size_estimate{0};
  rmm::device_scalar<size_type> size_estimate(0, stream);

  CHECK_CUDA(stream);

  constexpr int block_size{DEFAULT_JOIN_BLOCK_SIZE};
  int numBlocks{-1};

  CUDA_TRY(cudaOccupancyMaxActiveBlocksPerMultiprocessor(
    &numBlocks, compute_nested_loop_join_output_size<JoinKind, block_size>, block_size, 0));

  int dev_id{-1};
  CUDA_TRY(cudaGetDevice(&dev_id));

  int num_sms{-1};
  CUDA_TRY(cudaDeviceGetAttribute(&num_sms, cudaDevAttrMultiProcessorCount, dev_id));

  size_estimate.set_value(0);

  row_equality equality{left, right};
  // Determine number of output rows without actually building the output to simply
  // find what the size of the output will be.
  compute_nested_loop_join_output_size<JoinKind, block_size>
    <<<numBlocks * num_sms, block_size, 0, stream>>>(
      left, right, equality, left_num_rows, right_num_rows, size_estimate.data());
  CHECK_CUDA(stream);

  h_size_estimate = size_estimate.value();

  return h_size_estimate;
}

/* --------------------------------------------------------------------------*/
/**
 * @brief  Computes the join operation between two tables and returns the
 * output indices of left and right table as a combined table
 *
 * @param left  Table of left columns to join
 * @param right Table of right  columns to join
 * @param flip_join_indices Flag that indicates whether the left and right
 * tables have been flipped, meaning the output indices should also be flipped.
 * @param stream CUDA stream used for device memory operations and kernel launches.
 * @tparam join_kind The type of join to be performed
 *
 * @returns Join output indices vector pair
 */
/* ----------------------------------------------------------------------------*/
template <join_kind JoinKind>
std::enable_if_t<(JoinKind != join_kind::FULL_JOIN),
                 std::pair<rmm::device_vector<size_type>, rmm::device_vector<size_type>>>
get_base_nested_loop_join_indices(table_view const& left,
                                  table_view const& right,
                                  bool flip_join_indices,
                                  cudaStream_t stream)
{
  // The `right` table is always used for the inner loop. We want to use the smaller table
  // for the inner loop. Thus, if `left` is smaller than `right`, swap `left/right`.
  if ((JoinKind == join_kind::INNER_JOIN) && (right.num_rows() > left.num_rows())) {
    return get_base_nested_loop_join_indices<JoinKind>(right, left, true, stream);
  }
  // Trivial left join case - exit early
  if ((JoinKind == join_kind::LEFT_JOIN) && (right.num_rows() == 0)) {
    return get_trivial_left_join_indices(left, stream);
  }

  auto left_table  = table_device_view::create(left, stream);
  auto right_table = table_device_view::create(right, stream);

  size_type estimated_size =
    estimate_nested_loop_join_output_size<JoinKind>(*left_table, *right_table, stream);

  // If the estimated output size is zero, return immediately
  if (estimated_size == 0) {
    return std::make_pair(rmm::device_vector<size_type>{}, rmm::device_vector<size_type>{});
  }

  // Because we are approximating the number of joined elements, our approximation
  // might be incorrect and we might have underestimated the number of joined elements.
  // As such we will need to de-allocate memory and re-allocate memory to ensure
  // that the final output is correct.
  rmm::device_scalar<size_type> write_index(0, stream);
  size_type join_size{0};

  rmm::device_vector<size_type> left_indices;
  rmm::device_vector<size_type> right_indices;
  auto current_estimated_size = estimated_size;
  do {
    left_indices.resize(estimated_size);
    right_indices.resize(estimated_size);

    constexpr int block_size{DEFAULT_JOIN_BLOCK_SIZE};
    detail::grid_1d config(left_table->num_rows(), block_size);
    write_index.set_value(0);

    row_equality equality{*left_table, *right_table};
    nested_loop_join<JoinKind, block_size, DEFAULT_JOIN_CACHE_SIZE>
      <<<config.num_blocks, config.num_threads_per_block, 0, stream>>>(*left_table,
                                                                       *right_table,
                                                                       equality,
                                                                       left_table->num_rows(),
                                                                       right_table->num_rows(),
                                                                       left_indices.data().get(),
                                                                       right_indices.data().get(),
                                                                       write_index.data(),
                                                                       estimated_size,
                                                                       flip_join_indices);

    CHECK_CUDA(stream);

    join_size              = write_index.value();
    current_estimated_size = estimated_size;
    estimated_size *= 2;
  } while ((current_estimated_size < join_size));

  left_indices.resize(join_size);
  right_indices.resize(join_size);
  return std::make_pair(std::move(left_indices), std::move(right_indices));
}

}  // namespace detail

}  // namespace cudf
