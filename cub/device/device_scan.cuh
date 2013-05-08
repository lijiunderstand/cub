
/******************************************************************************
 * Copyright (c) 2011, Duane Merrill.  All rights reserved.
 * Copyright (c) 2011-2013, NVIDIA CORPORATION.  All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *     * Redistributions of source code must retain the above copyright
 *       notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above copyright
 *       notice, this list of conditions and the following disclaimer in the
 *       documentation and/or other materials provided with the distribution.
 *     * Neither the name of the NVIDIA CORPORATION nor the
 *       names of its contributors may be used to endorse or promote products
 *       derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL NVIDIA CORPORATION BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 ******************************************************************************/

/**
 * \file
 * cub::DeviceScan provides operations for computing a device-wide, parallel prefix scan across data items residing within global memory.
 */

#pragma once

#include <stdio.h>
#include <iterator>

#include "persistent_block/persistent_block_scan.cuh"
#include "../util_allocator.cuh"
#include "../grid/grid_even_share.cuh"
#include "../grid/grid_queue.cuh"
#include "../grid/grid_mapping.cuh"
#include "../util_debug.cuh"

/// Optional outer namespace(s)
CUB_NS_PREFIX

/// CUB namespace
namespace cub {


/******************************************************************************
 * Kernel entry points
 *****************************************************************************/

#ifndef DOXYGEN_SHOULD_SKIP_THIS    // Do not document


/**
 * Initialization kernel for queue descriptor preparation and for zeroing block status
 */
template <
    typename            TileStatus,         ///< Tile status word type
    typename            SizeT>              ///< Integral type used for global array indexing
__global__ void InitScanKernel(
    GridQueue<SizeT>    grid_queue,         ///< [in] Descriptor for performing dynamic mapping of input tiles to thread blocks
    TileStatus          *d_tile_status,     ///< [out] Tile status words
    int                 num_tiles)          ///< [in] Number of tiles
{
    enum
    {
        STATUS_PADDING = PtxArchProps::WARP_THREADS,
    };

    // Reset queue descriptor
    if ((blockIdx.x == 0) && (threadIdx.x == 0)) grid_queue.ResetDrain(num_tiles);

    // Initialize tile status
    int tile_offset = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (tile_offset < num_tiles)
    {
        // Not-yet-set
        d_tile_status[STATUS_PADDING + tile_offset] =  PERSISTENT_BLOCK_SCAN_INVALID;
    }
    if ((blockIdx.x == 0) && (threadIdx.x < STATUS_PADDING))
    {
        // Padding
        d_tile_status[threadIdx.x] = PERSISTENT_BLOCK_SCAN_OOB;
    }
}


/**
 * Multi-block histogram kernel entry point.  Computes privatized histograms, one per thread block.
 */
template <
    typename    PersistentBlockScanPolicy,  ///< Tuning policy for cub::PersistentBlockScan abstraction
    typename    InputIteratorRA,            ///< The random-access iterator type for input (may be a simple pointer type).
    typename    OutputIteratorRA,           ///< The random-access iterator type for output (may be a simple pointer type).
    typename    ScanOp,                     ///< Binary scan operator type having member <tt>T operator()(const T &a, const T &b)</tt>
    typename    Identity,                   ///< Identity value type (cub::NullType for inclusive scans)
    typename    SizeT>                      ///< Integral type used for global array indexing
__launch_bounds__ (int(PersistentBlockScanPolicy::BLOCK_THREADS))
__global__ void MultiBlockScanKernel(
    InputIteratorRA                                             d_in,               ///< Input data
    OutputIteratorRA                                            d_out,              ///< Output data
    typename std::iterator_traits<InputIteratorRA>::value_type  *d_tile_aggregates, ///< Global list of block aggregates
    typename std::iterator_traits<InputIteratorRA>::value_type  *d_tile_prefixes,   ///< Global list of block inclusive prefixes
    typename PersistentBlockScanPolicy::TileStatus              *d_tile_status,     ///< Global list of tile status
    ScanOp                                                      scan_op,            ///< Binary scan operator
    Identity                                                    identity,           ///< Identity element
    SizeT                                                       num_items,          ///< Total number of scan items for the entire problem
    int                                                         num_tiles,          ///< Total number of input tiles
    GridQueue<SizeT>                                            queue)              ///< Descriptor for performing dynamic mapping of tile data to thread blocks
{
    // Thread block type for scanning input tiles
    typedef PersistentBlockScan<
        PersistentBlockScanPolicy,
        InputIteratorRA,
        OutputIteratorRA,
        ScanOp,
        Identity,
        SizeT> PersistentBlockScanT;

    // Shared memory for PersistentBlockScan
    __shared__ typename PersistentBlockScanT::SmemStorage smem_storage;

    // Thread block instance
    PersistentBlockScanT persistent_block(
        smem_storage,
        d_in,
        d_out,
        d_tile_aggregates,
        d_tile_prefixes,
        d_tile_status,
        scan_op,
        identity,
        num_items);

    // Consume tiles using thread block instance
    int dummy_result;
    ConsumeTiles(persistent_block, num_tiles, queue, dummy_result);
}


#endif // DOXYGEN_SHOULD_SKIP_THIS



/******************************************************************************
 * DeviceScan
 *****************************************************************************/

/**
 * \addtogroup DeviceModule
 * @{
 */

/**
 * \brief DeviceScan provides operations for computing a device-wide, parallel prefix scan across data items residing within global memory. ![](scan_logo.png)
 */
struct DeviceScan
{
#ifndef DOXYGEN_SHOULD_SKIP_THIS    // Do not document


    /// Generic structure for encapsulating dispatch properties.  Mirrors the constants within PersistentBlockScanPolicy.
    struct KernelDispachParams
    {
        // Policy fields
        int                         block_threads;
        int                         items_per_thread;
        PersistentBlockScanAlgorithm  block_algorithm;
        GridMappingStrategy         grid_mapping;
        int                         subscription_factor;

        // Derived fields
        int                         tile_size;

        template <typename PersistentBlockScanPolicy>
        __host__ __device__ __forceinline__
        void Init(int subscription_factor = 1)
        {
            block_threads               = PersistentBlockScanPolicy::BLOCK_THREADS;
            items_per_thread            = PersistentBlockScanPolicy::ITEMS_PER_THREAD;
            block_algorithm             = PersistentBlockScanPolicy::GRID_ALGORITHM;
            grid_mapping                = PersistentBlockScanPolicy::GRID_MAPPING;
            this->subscription_factor   = subscription_factor;

            tile_size                   = block_threads * items_per_thread;
        }

        __host__ __device__ __forceinline__
        void Print()
        {
            printf("%d, %d, %d, %d, %d",
                block_threads,
                items_per_thread,
                block_algorithm,
                grid_mapping,
                subscription_factor);
        }

    };


    /// Specializations of tuned policy types for different PTX architectures
    template <
        int                         CHANNELS,
        int                         ACTIVE_CHANNELS,
        PersistentBlockScanAlgorithm      GRID_ALGORITHM,
        int                         ARCH>
    struct TunedPolicies;

    /// SM35 tune
    template <int CHANNELS, int ACTIVE_CHANNELS, PersistentBlockScanAlgorithm GRID_ALGORITHM>
    struct TunedPolicies<CHANNELS, ACTIVE_CHANNELS, GRID_ALGORITHM, 350>
    {
        typedef PersistentBlockScanPolicy<
            (GRID_ALGORITHM == GRID_HISTO_256_SORT) ? 128 : 256,
            (GRID_ALGORITHM == GRID_HISTO_256_SORT) ? 12 : (30 / ACTIVE_CHANNELS),
            GRID_ALGORITHM,
            (GRID_ALGORITHM == GRID_HISTO_256_SORT) ? GRID_MAPPING_DYNAMIC : GRID_MAPPING_EVEN_SHARE,
            (GRID_ALGORITHM == GRID_HISTO_256_SORT) ? 8 : 1> MultiBlockPolicy;
        enum { SUBSCRIPTION_FACTOR = 7 };
    };

    /// SM30 tune
    template <int CHANNELS, int ACTIVE_CHANNELS, PersistentBlockScanAlgorithm GRID_ALGORITHM>
    struct TunedPolicies<CHANNELS, ACTIVE_CHANNELS, GRID_ALGORITHM, 300>
    {
        typedef PersistentBlockScanPolicy<
            128,
            (GRID_ALGORITHM == GRID_HISTO_256_SORT) ? 20 : (22 / ACTIVE_CHANNELS),
            GRID_ALGORITHM,
            (GRID_ALGORITHM == GRID_HISTO_256_SORT) ? GRID_MAPPING_DYNAMIC : GRID_MAPPING_EVEN_SHARE,
            1> MultiBlockPolicy;
        enum { SUBSCRIPTION_FACTOR = 1 };
    };

    /// SM20 tune
    template <int CHANNELS, int ACTIVE_CHANNELS, PersistentBlockScanAlgorithm GRID_ALGORITHM>
    struct TunedPolicies<CHANNELS, ACTIVE_CHANNELS, GRID_ALGORITHM, 200>
    {
        typedef PersistentBlockScanPolicy<
            128,
            (GRID_ALGORITHM == GRID_HISTO_256_SORT) ? 21 : (23 / ACTIVE_CHANNELS),
            GRID_ALGORITHM,
            GRID_MAPPING_DYNAMIC,
            1> MultiBlockPolicy;
        enum { SUBSCRIPTION_FACTOR = 1 };
    };

    /// SM10 tune
    template <int CHANNELS, int ACTIVE_CHANNELS, PersistentBlockScanAlgorithm GRID_ALGORITHM>
    struct TunedPolicies<CHANNELS, ACTIVE_CHANNELS, GRID_ALGORITHM, 100>
    {
        typedef PersistentBlockScanPolicy<
            128, 
            7, 
            GRID_HISTO_256_SORT,        // (use sort regardless because atomics are perf-useless)
            GRID_MAPPING_EVEN_SHARE,
            1> MultiBlockPolicy;
        enum { SUBSCRIPTION_FACTOR = 1 };
    };


    /// Tuning policy(ies) for the PTX architecture that DeviceScan operations will get dispatched to
    template <
        int                         CHANNELS,
        int                         ACTIVE_CHANNELS,
        PersistentBlockScanAlgorithm      GRID_ALGORITHM>
    struct PtxDefaultPolicies
    {
        static const int PTX_TUNE_ARCH =   (CUB_PTX_ARCH >= 350) ?
                                                350 :
                                                (CUB_PTX_ARCH >= 300) ?
                                                    300 :
                                                    (CUB_PTX_ARCH >= 200) ?
                                                        200 :
                                                        100;

        // Tuned policy set for the current PTX compiler pass
        typedef TunedPolicies<CHANNELS, ACTIVE_CHANNELS, GRID_ALGORITHM, PTX_TUNE_ARCH> PtxPassTunedPolicies;

        // Subscription factor for the current PTX compiler pass
        static const int SUBSCRIPTION_FACTOR = PtxPassTunedPolicies::SUBSCRIPTION_FACTOR;

        // MultiBlockPolicy that opaquely derives from the specialization corresponding to the current PTX compiler pass
        struct MultiBlockPolicy : PtxPassTunedPolicies::MultiBlockPolicy {};

        /**
         * Initialize dispatch params with the policies corresponding to the PTX assembly we will use
         */
        static void InitDispatchParams(int ptx_version, KernelDispachParams &multi_block_dispatch_params)
        {
            if (ptx_version >= 350)
            {
                typedef TunedPolicies<CHANNELS, ACTIVE_CHANNELS, GRID_ALGORITHM, 350> TunedPolicies;
                multi_block_dispatch_params.Init<typename TunedPolicies::MultiBlockPolicy>(TunedPolicies::SUBSCRIPTION_FACTOR);
            }
            else if (ptx_version >= 300)
            {
                typedef TunedPolicies<CHANNELS, ACTIVE_CHANNELS, GRID_ALGORITHM, 300> TunedPolicies;
                multi_block_dispatch_params.Init<typename TunedPolicies::MultiBlockPolicy>(TunedPolicies::SUBSCRIPTION_FACTOR);
            }
            else if (ptx_version >= 200)
            {
                typedef TunedPolicies<CHANNELS, ACTIVE_CHANNELS, GRID_ALGORITHM, 200> TunedPolicies;
                multi_block_dispatch_params.Init<typename TunedPolicies::MultiBlockPolicy>(TunedPolicies::SUBSCRIPTION_FACTOR);
            }
            else
            {
                typedef TunedPolicies<CHANNELS, ACTIVE_CHANNELS, GRID_ALGORITHM, 100> TunedPolicies;
                multi_block_dispatch_params.Init<typename TunedPolicies::MultiBlockPolicy>(TunedPolicies::SUBSCRIPTION_FACTOR);
            }
        }
    };





    /**
     * Internal dispatch routine for invoking device-wide, multi-channel, 256-bin histogram
     */
    template <
        int                             CHANNELS,                                           ///< Number of channels interleaved in the input data (may be greater than the number of channels being actively histogrammed)
        int                             ACTIVE_CHANNELS,                                    ///< Number of channels actively being histogrammed
        typename                        InitScanKernelPtr,                              ///< Function type of cub::InitScanKernel
        typename                        MultiBlockScanKernelPtr,                        ///< Function type of cub::MultiBlockScanKernel
        typename                        AggregateScanKernelPtr,                         ///< Function type of cub::AggregateScanKernel
        typename                        InputIteratorRA,                                    ///< The input iterator type (may be a simple pointer type).  Must have a value type that is assignable to <tt>unsigned char</tt>
        typename                        HistoCounter,                                       ///< Integral type for counting sample occurrences per histogram bin
        typename                        SizeT>                                              ///< Integral type used for global array indexing
    __host__ __device__ __forceinline__
    static cudaError_t Dispatch(
        InitScanKernelPtr           init_kernel_ptr,                                    ///< [in] Kernel function pointer to parameterization of cub::InitScanKernel
        MultiBlockScanKernelPtr     multi_block_kernel_ptr,                             ///< [in] Kernel function pointer to parameterization of cub::MultiBlockScanKernel
        AggregateScanKernelPtr      aggregate_kernel_ptr,                               ///< [in] Kernel function pointer to parameterization of cub::AggregateScanKernel
        KernelDispachParams             &multi_block_dispatch_params,                       ///< [in] Dispatch parameters that match the policy that \p multi_block_kernel_ptr was compiled for
        InputIteratorRA                 d_samples,                                          ///< [in] Input samples to histogram
        HistoCounter                    *(&d_histograms)[ACTIVE_CHANNELS],                  ///< [out] Array of channel histograms, each having 256 counters of integral type \p HistoCounter.
        SizeT                           num_samples,                                        ///< [in] Number of samples to process
        cudaStream_t                    stream              = 0,                            ///< [in] <b>[optional]</b> CUDA stream to launch kernels within.  Default is stream-0.
        bool                            stream_synchronous  = false,                        ///< [in] <b>[optional]</b> Whether or not to synchronize the stream after every kernel launch to check for errors.  Default is \p false.
        DeviceAllocator                 *device_allocator   = DefaultDeviceAllocator())     ///< [in] <b>[optional]</b> Allocator for allocating and freeing device memory.  Default is provided by DefaultDeviceAllocator.
    {
    #ifndef CUB_RUNTIME_ENABLED

        // Kernel launch not supported from this device
        return CubDebug(cudaErrorInvalidConfiguration);

    #else

        HistoCounter            *d_block_histograms_linear = NULL;  // Temporary storage
        GridEvenShare<SizeT>    even_share;                         // Even-share work distribution
        GridQueue<SizeT>        queue;                              // Dynamic, queue-based work distribution

        cudaError error = cudaSuccess;
        do
        {
            // Setup array wrapper for histogram channel output because we can't pass static arrays as kernel parameters
            ArrayWrapper<HistoCounter*, ACTIVE_CHANNELS> d_histo_wrapper;
            for (int CHANNEL = 0; CHANNEL < ACTIVE_CHANNELS; ++CHANNEL)
            {
                d_histo_wrapper.array[CHANNEL] = d_histograms[CHANNEL];
            }

            // Initialize counters and queue descriptor if necessary
            if ((multi_block_dispatch_params.grid_mapping == GRID_MAPPING_DYNAMIC) ||
                (multi_block_dispatch_params.block_algorithm == GRID_HISTO_256_GLOBAL_ATOMIC))
            {
                queue.Allocate(device_allocator);

                if (stream_synchronous) CubLog("Invoking init_kernel_ptr<<<%d, 256, 0, %d>>>()\n", ACTIVE_CHANNELS, (int) stream);

                init_kernel_ptr<<<ACTIVE_CHANNELS, 256, 0, stream>>>(queue, d_histo_wrapper, num_samples);

            #ifndef __CUDA_ARCH__
                // Sync the stream on the host
                if (stream_synchronous && CubDebug(error = cudaStreamSynchronize(stream))) break;
            #else
                // Sync the entire device on the device (cudaStreamSynchronize doesn't exist on device)
                if (stream_synchronous && CubDebug(error = cudaDeviceSynchronize())) break;
            #endif
            }

            // Determine grid size for the multi-block kernel

            int device_ordinal;
            if (CubDebug(error = cudaGetDevice(&device_ordinal))) break;

            int sm_count;
            if (CubDebug(error = cudaDeviceGetAttribute (&sm_count, cudaDevAttrMultiProcessorCount, device_ordinal))) break;

            // Rough estimate of SM occupancies based upon the maximum SM occupancy of the targeted PTX architecture
            int multi_sm_occupancy = CUB_MIN(
                ArchProps<CUB_PTX_ARCH>::MAX_SM_THREADBLOCKS,
                ArchProps<CUB_PTX_ARCH>::MAX_SM_THREADS / multi_block_dispatch_params.block_threads);

        #ifndef __CUDA_ARCH__

            // We're on the host, so come up with a more accurate estimate of SM occupancies from actual device properties
            Device device_props;
            if (CubDebug(error = device_props.Init(device_ordinal))) break;

            if (CubDebug(error = device_props.MaxSmOccupancy(
                multi_sm_occupancy,
                multi_block_kernel_ptr,
                multi_block_dispatch_params.block_threads))) break;

        #endif

            int multi_occupancy = multi_sm_occupancy * sm_count;
            int multi_tile_size = multi_block_dispatch_params.block_threads * multi_block_dispatch_params.items_per_thread;
            int multi_grid_size;

            switch (multi_block_dispatch_params.grid_mapping)
            {
            case GRID_MAPPING_EVEN_SHARE:

                // Work is distributed evenly
                even_share.GridInit(
                    num_samples,
                    multi_occupancy * multi_block_dispatch_params.subscription_factor,
                    multi_tile_size);

                // Set MultiBlock grid size
                multi_grid_size = even_share.grid_size;
                break;

            case GRID_MAPPING_DYNAMIC:

                // Prepare queue to distribute work dynamically
                int num_tiles = (num_samples + multi_tile_size - 1) / multi_tile_size;

                // Set MultiBlock grid size
                multi_grid_size = (num_tiles < multi_occupancy) ?
                    num_tiles :                 // Not enough to fill the device with threadblocks
                    multi_occupancy;            // Fill the device with threadblocks

                break;
            };

            // Bind textures if the iterator supports it
        #ifndef __CUDA_ARCH__
            if (CubDebug(error = BindIteratorTexture(d_samples))) break;
        #endif // __CUDA_ARCH__

            // Invoke MultiBlockScan
            if (stream_synchronous) CubLog("Invoking multi_block_kernel_ptr<<<%d, %d, 0, %d>>>(), %d items per thread, %d SM occupancy\n",
                multi_grid_size, multi_block_dispatch_params.block_threads, (int) stream, multi_block_dispatch_params.items_per_thread, multi_sm_occupancy);

            if ((multi_grid_size == 1) || (multi_block_dispatch_params.block_algorithm == GRID_HISTO_256_GLOBAL_ATOMIC))
            {
                // A single pass will do
                multi_block_kernel_ptr<<<multi_grid_size, multi_block_dispatch_params.block_threads, 0, stream>>>(
                    d_samples,
                    d_histo_wrapper,
                    num_samples,
                    even_share,
                    queue);
            }
            else
            {
                // Use two-pass approach to compute and reduce privatized block histograms

                // Allocate temporary storage for privatized thread block histograms in each channel
                if (CubDebug(error = DeviceAllocate(
                    (void**) &d_block_histograms_linear,
                    ACTIVE_CHANNELS * multi_grid_size * sizeof(HistoCounter) * 256,
                    device_allocator))) break;

                // Setup array wrapper for temporary histogram channel output because we can't pass static arrays as kernel parameters
                ArrayWrapper<HistoCounter*, ACTIVE_CHANNELS> d_temp_histo_wrapper;
                for (int CHANNEL = 0; CHANNEL < ACTIVE_CHANNELS; ++CHANNEL)
                {
                    d_temp_histo_wrapper.array[CHANNEL] = d_block_histograms_linear + (CHANNEL * multi_grid_size * 256);
                }

                multi_block_kernel_ptr<<<multi_grid_size, multi_block_dispatch_params.block_threads, 0, stream>>>(
                    d_samples,
                    d_temp_histo_wrapper,
                    num_samples,
                    even_share,
                    queue);

                #ifndef __CUDA_ARCH__
                    // Sync the stream on the host
                    if (stream_synchronous && CubDebug(error = cudaStreamSynchronize(stream))) break;
                #else
                    // Sync the entire device on the device (cudaStreamSynchronize doesn't exist on device)
                    if (stream_synchronous && CubDebug(error = cudaDeviceSynchronize())) break;
                #endif

                if (stream_synchronous) CubLog("Invoking aggregate_kernel_ptr<<<%d, %d, 0, %d>>>()\n",
                    ACTIVE_CHANNELS, 256, (int) stream);

                aggregate_kernel_ptr<<<ACTIVE_CHANNELS, 256, 0, stream>>>(
                    d_block_histograms_linear,
                    d_histo_wrapper,
                    multi_grid_size);
            }

            #ifndef __CUDA_ARCH__
                // Sync the stream on the host
                if (stream_synchronous && CubDebug(error = cudaStreamSynchronize(stream))) break;
            #else
                // Sync the entire device on the device (cudaStreamSynchronize doesn't exist on device)
                if (stream_synchronous && CubDebug(error = cudaDeviceSynchronize())) break;
            #endif
        }
        while (0);

        // Free temporary storage allocation
        if (d_block_histograms_linear)
            error = CubDebug(DeviceFree(d_block_histograms_linear, device_allocator));

        // Free queue allocation
        if ((multi_block_dispatch_params.grid_mapping == GRID_MAPPING_DYNAMIC) ||
            (multi_block_dispatch_params.block_algorithm == GRID_HISTO_256_GLOBAL_ATOMIC))
        {
            error = CubDebug(queue.Free(device_allocator));
        }

        // Unbind texture
    #ifndef __CUDA_ARCH__
        error = CubDebug(UnbindIteratorTexture(d_samples));
    #endif // __CUDA_ARCH__

        return error;

    #endif
    }


    /**
     * \brief Computes a 256-bin device-wide histogram
     *
     * \tparam GRID_ALGORITHM      cub::PersistentBlockScanAlgorithm enumerator specifying the underlying algorithm to use
     * \tparam CHANNELS             Number of channels interleaved in the input data (may be greater than the number of channels being actively histogrammed)
     * \tparam ACTIVE_CHANNELS      <b>[inferred]</b> Number of channels actively being histogrammed
     * \tparam InputIteratorRA      <b>[inferred]</b> The random-access iterator type for input (may be a simple pointer type).  Must have a value type that is assignable to <tt>unsigned char</tt>
     * \tparam HistoCounter         <b>[inferred]</b> Integral type for counting sample occurrences per histogram bin
     */
    template <
        PersistentBlockScanAlgorithm  GRID_ALGORITHM,
        int                         CHANNELS,                                           ///< Number of channels interleaved in the input data (may be greater than the number of channels being actively histogrammed)
        int                         ACTIVE_CHANNELS,                                    ///< Number of channels actively being histogrammed
        typename                    InputIteratorRA,
        typename                    HistoCounter>
    __host__ __device__ __forceinline__
    static cudaError_t Dispatch(
        InputIteratorRA         d_samples,                                          ///< [in] Input samples to histogram
        HistoCounter            *(&d_histograms)[ACTIVE_CHANNELS],                  ///< [out] Array of channel histograms, each having 256 counters of integral type \p HistoCounter.
        int                     num_samples,                                        ///< [in] Number of samples to process
        cudaStream_t            stream              = 0,                            ///< [in] <b>[optional]</b> CUDA stream to launch kernels within.  Default is stream-0.
        bool                    stream_synchronous  = false,                        ///< [in] <b>[optional]</b> Whether or not to synchronize the stream after every kernel launch to check for errors.  Default is \p false.
        DeviceAllocator*        device_allocator    = DefaultDeviceAllocator())     ///< [in] <b>[optional]</b> Allocator for allocating and freeing device memory.  Default is provided by DefaultDeviceAllocator.
    {
        // Type used for array indexing
        typedef int SizeT;

        // Tuning polices for the PTX architecture that will get dispatched to
        typedef PtxDefaultPolicies<CHANNELS, ACTIVE_CHANNELS, GRID_ALGORITHM> PtxDefaultPolicies;
        typedef typename PtxDefaultPolicies::MultiBlockPolicy MultiBlockPolicy;

        cudaError error = cudaSuccess;
        do
        {
            // Declare dispatch parameters
            KernelDispachParams multi_block_dispatch_params;

        #ifdef __CUDA_ARCH__

            // We're on the device, so initialize the dispatch parameters with the PtxDefaultPolicies directly
            multi_block_dispatch_params.Init<MultiBlockPolicy>(PtxDefaultPolicies::SUBSCRIPTION_FACTOR);

        #else

            // We're on the host, so lookup and initialize the dispatch parameters with the policies that match the device's PTX version
            int ptx_version;
            if (CubDebug(error = PtxVersion(ptx_version))) break;
            PtxDefaultPolicies::InitDispatchParams(ptx_version, multi_block_dispatch_params);

        #endif

            Dispatch<CHANNELS, ACTIVE_CHANNELS>(
                InitScanKernel<ACTIVE_CHANNELS, SizeT, HistoCounter>,
                MultiBlockScanKernel<MultiBlockPolicy, CHANNELS, ACTIVE_CHANNELS, InputIteratorRA, HistoCounter, SizeT>,
                AggregateScanKernel<ACTIVE_CHANNELS, HistoCounter>,
                multi_block_dispatch_params,
                d_samples,
                d_histograms,
                num_samples,
                stream,
                stream_synchronous,
                device_allocator);

            if (CubDebug(error)) break;
        }
        while (0);

        return error;
    }

    #endif // DOXYGEN_SHOULD_SKIP_THIS


    //---------------------------------------------------------------------
    // Public interface
    //---------------------------------------------------------------------

    /**
     * \brief Computes a 256-bin device-wide histogram.  Uses fast block-sorting to compute the histogram.
     *
     * Delivers consistent throughput regardless of sample diversity.
     *
     * \tparam InputIteratorRA      <b>[inferred]</b> The random-access iterator type for input (may be a simple pointer type).  Must have a value type that is assignable to <tt>unsigned char</tt>
     * \tparam HistoCounter         <b>[inferred]</b> Integral type for counting sample occurrences per histogram bin
     */
    template <
        typename            InputIteratorRA,
        typename            HistoCounter>
    __host__ __device__ __forceinline__
    static cudaError_t SingleChannel(
        InputIteratorRA     d_samples,                                          ///< [in] Input samples
        HistoCounter*       d_histogram,                                        ///< [out] Array of 256 counters of integral type \p HistoCounter.
        int                 num_samples,                                        ///< [in] Number of samples to process
        cudaStream_t        stream              = 0,                            ///< [in] <b>[optional]</b> CUDA stream to launch kernels within.  Default is stream-0.
        bool                stream_synchronous  = false,                        ///< [in] <b>[optional]</b> Whether or not to synchronize the stream after every kernel launch to check for errors.  Default is \p false.
        DeviceAllocator*    device_allocator    = DefaultDeviceAllocator())     ///< [in] <b>[optional]</b> Allocator for allocating and freeing device memory.  Default is provided by DefaultDeviceAllocator.
    {
        return Dispatch<GRID_HISTO_256_SORT, 1, 1>(
            d_samples, &d_histogram, num_samples, stream, stream_synchronous, device_allocator);
    }

    /**
     * \brief Computes a 256-bin device-wide histogram.  Uses shared-memory atomic read-modify-write operations to compute the histogram.
     *
     * Sample input having lower diversity cause performance to be degraded.
     *
     * \tparam InputIteratorRA      <b>[inferred]</b> The random-access iterator type for input (may be a simple pointer type).  Must have a value type that is assignable to <tt>unsigned char</tt>
     * \tparam HistoCounter         <b>[inferred]</b> Integral type for counting sample occurrences per histogram bin
     */
    template <
        typename            InputIteratorRA,
        typename            HistoCounter>
    __host__ __device__ __forceinline__
    static cudaError_t SingleChannelAtomic(
        InputIteratorRA     d_samples,                                          ///< [in] Input samples
        HistoCounter*       d_histogram,                                        ///< [out] Array of 256 counters of integral type \p HistoCounter.
        int                 num_samples,                                        ///< [in] Number of samples to process
        cudaStream_t        stream              = 0,                            ///< [in] <b>[optional]</b> CUDA stream to launch kernels within.  Default is stream-0.
        bool                stream_synchronous  = false,                        ///< [in] <b>[optional]</b> Whether or not to synchronize the stream after every kernel launch to check for errors.  Default is \p false.
        DeviceAllocator*    device_allocator    = DefaultDeviceAllocator())     ///< [in] <b>[optional]</b> Allocator for allocating and freeing device memory.  Default is provided by DefaultDeviceAllocator.
    {
        return Dispatch<GRID_HISTO_256_SHARED_ATOMIC, 1, 1>(
            d_samples, &d_histogram, num_samples, stream, stream_synchronous, device_allocator);
    }


    /**
     * \brief Computes a 256-bin device-wide histogram.  Uses global-memory atomic read-modify-write operations to compute the histogram.
     *
     * Sample input having lower diversity cause performance to be degraded.
     *
     * \tparam InputIteratorRA      <b>[inferred]</b> The random-access iterator type for input (may be a simple pointer type).  Must have a value type that is assignable to <tt>unsigned char</tt>
     * \tparam HistoCounter         <b>[inferred]</b> Integral type for counting sample occurrences per histogram bin
     */
    template <
        typename            InputIteratorRA,
        typename            HistoCounter>
    __host__ __device__ __forceinline__
    static cudaError_t SingleChannelGlobalAtomic(
        InputIteratorRA     d_samples,                                          ///< [in] Input samples
        HistoCounter*       d_histogram,                                        ///< [out] Array of 256 counters of integral type \p HistoCounter.
        int                 num_samples,                                        ///< [in] Number of samples to process
        cudaStream_t        stream              = 0,                            ///< [in] <b>[optional]</b> CUDA stream to launch kernels within.  Default is stream-0.
        bool                stream_synchronous  = false,                        ///< [in] <b>[optional]</b> Whether or not to synchronize the stream after every kernel launch to check for errors.  Default is \p false.
        DeviceAllocator*    device_allocator    = DefaultDeviceAllocator())     ///< [in] <b>[optional]</b> Allocator for allocating and freeing device memory.  Default is provided by DefaultDeviceAllocator.
    {
        return Dispatch<GRID_HISTO_256_GLOBAL_ATOMIC, 1, 1>(
            d_samples, &d_histogram, num_samples, stream, stream_synchronous, device_allocator);
    }


    /**
     * \brief Computes a 256-bin device-wide histogram from multi-channel data.  Uses fast block-sorting to compute the histogram.
     *
     * Delivers consistent throughput regardless of sample diversity.
     *
     * \tparam CHANNELS             Number of channels interleaved in the input data (may be greater than the number of channels being actively histogrammed)
     * \tparam ACTIVE_CHANNELS      <b>[inferred]</b> Number of channels actively being histogrammed
     * \tparam InputIteratorRA      <b>[inferred]</b> The random-access iterator type for input (may be a simple pointer type).  Must have a value type that is assignable to <tt>unsigned char</tt>
     * \tparam HistoCounter         <b>[inferred]</b> Integral type for counting sample occurrences per histogram bin
     */
    template <
        int                 CHANNELS,
        int                 ACTIVE_CHANNELS,
        typename            InputIteratorRA,
        typename            HistoCounter>
    __host__ __device__ __forceinline__
    static cudaError_t MultiChannel(
        InputIteratorRA     d_samples,                                          ///< [in] Input samples. (Channels, if any, are interleaved in "AOS" format)
        HistoCounter        *(&d_histograms)[ACTIVE_CHANNELS],                  ///< [out] Array of channel histograms, each having 256 counters of integral type \p HistoCounter.
        int                 num_samples,                                        ///< [in] Number of samples to process
        cudaStream_t        stream              = 0,                            ///< [in] <b>[optional]</b> CUDA stream to launch kernels within.  Default is stream-0.
        bool                stream_synchronous  = false,                        ///< [in] <b>[optional]</b> Whether or not to synchronize the stream after every kernel launch to check for errors.  Default is \p false.
        DeviceAllocator*    device_allocator    = DefaultDeviceAllocator())     ///< [in] <b>[optional]</b> Allocator for allocating and freeing device memory.  Default is provided by DefaultDeviceAllocator.
    {
        return Dispatch<GRID_HISTO_256_SORT, CHANNELS, ACTIVE_CHANNELS>(
            d_samples, d_histograms, num_samples, stream, stream_synchronous, device_allocator);
    }


    /**
     * \brief Computes a 256-bin device-wide histogram from multi-channel data.  Uses shared-memory atomic read-modify-write operations to compute the histogram.
     *
     * Sample input having lower diversity cause performance to be degraded.
     *
     * \tparam CHANNELS             Number of channels interleaved in the input data (may be greater than the number of channels being actively histogrammed)
     * \tparam ACTIVE_CHANNELS      <b>[inferred]</b> Number of channels actively being histogrammed
     * \tparam InputIteratorRA      <b>[inferred]</b> The random-access iterator type for input (may be a simple pointer type).  Must have a value type that is assignable to <tt>unsigned char</tt>
     * \tparam HistoCounter         <b>[inferred]</b> Integral type for counting sample occurrences per histogram bin
     */
    template <
        int                 CHANNELS,                                           ///< Number of channels interleaved in the input data (may be greater than the number of channels being actively histogrammed)
        int                 ACTIVE_CHANNELS,                                    ///< Number of channels actively being histogrammed
        typename            InputIteratorRA,
        typename            HistoCounter>
    __host__ __device__ __forceinline__
    static cudaError_t MultiChannelAtomic(
        InputIteratorRA     d_samples,                                          ///< [in] Input samples. (Channels, if any, are interleaved in "AOS" format)
        HistoCounter        *(&d_histograms)[ACTIVE_CHANNELS],                  ///< [out] Array of channel histograms, each having 256 counters of integral type \p HistoCounter.
        int                 num_samples,                                        ///< [in] Number of samples to process
        cudaStream_t        stream              = 0,                            ///< [in] <b>[optional]</b> CUDA stream to launch kernels within.  Default is stream-0.
        bool                stream_synchronous  = false,                        ///< [in] <b>[optional]</b> Whether or not to synchronize the stream after every kernel launch to check for errors.  Default is \p false.
        DeviceAllocator*    device_allocator    = DefaultDeviceAllocator())     ///< [in] <b>[optional]</b> Allocator for allocating and freeing device memory.  Default is provided by DefaultDeviceAllocator.
    {
        return Dispatch<GRID_HISTO_256_SHARED_ATOMIC, CHANNELS, ACTIVE_CHANNELS>(
            d_samples, d_histograms, num_samples, stream, stream_synchronous, device_allocator);
    }


    /**
     * \brief Computes a 256-bin device-wide histogram from multi-channel data.  Uses global-memory atomic read-modify-write operations to compute the histogram.
     *
     * Sample input having lower diversity cause performance to be degraded.
     *
     * \tparam CHANNELS             Number of channels interleaved in the input data (may be greater than the number of channels being actively histogrammed)
     * \tparam ACTIVE_CHANNELS      <b>[inferred]</b> Number of channels actively being histogrammed
     * \tparam InputIteratorRA      <b>[inferred]</b> The random-access iterator type for input (may be a simple pointer type).  Must have a value type that is assignable to <tt>unsigned char</tt>
     * \tparam HistoCounter         <b>[inferred]</b> Integral type for counting sample occurrences per histogram bin
     */
    template <
        int                 CHANNELS,                                           ///< Number of channels interleaved in the input data (may be greater than the number of channels being actively histogrammed)
        int                 ACTIVE_CHANNELS,                                    ///< Number of channels actively being histogrammed
        typename            InputIteratorRA,
        typename            HistoCounter>
    __host__ __device__ __forceinline__
    static cudaError_t MultiChannelGlobalAtomic(
        InputIteratorRA     d_samples,                                          ///< [in] Input samples. (Channels, if any, are interleaved in "AOS" format)
        HistoCounter        *(&d_histograms)[ACTIVE_CHANNELS],                  ///< [out] Array of channel histograms, each having 256 counters of integral type \p HistoCounter.
        int                 num_samples,                                        ///< [in] Number of samples to process
        cudaStream_t        stream              = 0,                            ///< [in] <b>[optional]</b> CUDA stream to launch kernels within.  Default is stream-0.
        bool                stream_synchronous  = false,                        ///< [in] <b>[optional]</b> Whether or not to synchronize the stream after every kernel launch to check for errors.  Default is \p false.
        DeviceAllocator*    device_allocator    = DefaultDeviceAllocator())     ///< [in] <b>[optional]</b> Allocator for allocating and freeing device memory.  Default is provided by DefaultDeviceAllocator.
    {
        return Dispatch<GRID_HISTO_256_GLOBAL_ATOMIC, CHANNELS, ACTIVE_CHANNELS>(
            d_samples, d_histograms, num_samples, stream, stream_synchronous, device_allocator);
    }


};


/** @} */       // DeviceModule

}               // CUB namespace
CUB_NS_POSTFIX  // Optional outer namespace(s)


