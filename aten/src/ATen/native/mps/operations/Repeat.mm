//  Copyright © 2022 Apple Inc.

#include <ATen/ATen.h>
#include <ATen/Tensor.h>
#include <ATen/Utils.h>
#include <ATen/Dispatch.h>
#include <ATen/Parallel.h>

#include <ATen/mps/MPSStream.h>
#include <ATen/native/LinearAlgebraUtils.h>
#include <ATen/native/Repeat.h>
#include <ATen/native/mps/OperationUtils.h>
#include <torch/library.h>
#include <c10/util/irange.h>

#ifndef AT_PER_OPERATOR_HEADERS
#include <ATen/NativeFunctions.h>
#else
#include <ATen/ops/repeat_interleave_native.h>
#endif

#ifdef __OBJC__
#include <MetalPerformanceShaders/MetalPerformanceShaders.h>
#endif

template <typename index_t>
kernel void compute_mps_kernel(at::mps:device int64_t* _repeat_ptr,
    	at::mps:device int64_t* _cumsum_ptr,
    	at::mps:device index_t* _result_ptr,
      uint idx [[thread_position_in_grid]])
    {

      using namespace mps;

    	int64_t stride = (threadGroupSize * block) / C10_WARP_SIZE;
    	int warp_id = idx / C10_WARP_SIZE;
    	int tid_in_warp = idx % C10_WARP_SIZE;
    	for (int64_t i = warp_id; i < size; i += stride)
    	{
    		int64_t end = _cumsum_ptr[i];
    		index_t repeat = _repeat_ptr[i];
    		for (int64_t j = start + tid_in_warp; j < end; j += C10_WARP_SIZE)
    		{
    			result_ptr[j] = i;
    		}
    	}
    }

template <typename index_t>
void compute_mps(index_t* repeat_ptr,
    int64_t* cumsum_ptr,
    index_t* result_ptr,
    int64_t size,
    int64_t result_size) {
    
    using namespace at::mps;

            int64_t block = 512;
    			  int64_t warps_per_block = block / C10_WARP_SIZE;

    			  NSUInteger threadGroupSize = ((size + warps_per_block - 1) / warps_per_block);
    			  if (threadGroupSize > 2048)
    			  {
    				  threadGroupSize = 2048;
    			  }

  MPSStream *mpsStream = getCurrentMPSStream();
  id<MTLDevice> device = MPSDevice::getInstance()->device();

dispatch_sync(mpsStream->queue(), ^(){
@autoreleasepool {
  NSError* error = nil;


  MTLSize gridSize = MTLSizeMake(threadGroupSize, 1, 1);
  id<MTLCommandBuffer> commandBuffer = mpsStream->commandBuffer();
  id<MTLComputeCommandEncoder> computeEncoder = [commandBuffer computeCommandEncoder];
  id<MTLFunction> addFunction = MPSDevice::getInstance()->metalIndexingFunction("compute_mps_kernel", nil);
  id<MTLComputePipelineState> _mAddFunctionPSO = [device newComputePipelineStateWithFunction: addFunction error:&error];

  id<MTLBuffer> _repeat_ptr = [device newBufferWithLength:size options:MTLResourceStorageModeShared];
  id<MTLBuffer> _cumsum_ptr = [device newBufferWithLength:size options:MTLResourceStorageModeShared];
  id<MTLBuffer> _result_ptr = [device newBufferWithLength:result_size options:MTLResourceStorageModeShared];

  _repeat_ptr.contents = repeat_ptr;
  _cumsum_ptr.contents = cumsum_ptr;

  [computeEncoder setComputePipelineState:_mAddFunctionPSO];
  [computeEncoder setBuffer:_repeat_ptr offset:0 atIndex:0];
  [computeEncoder setBuffer:_cumsum_ptr offset:0 atIndex:0];
  [computeEncoder setBuffer:_result_ptr offset:0 atIndex:0];

  [computeEncoder dispatchThreads:gridSize
          threadsPerThreadgroup:threadgroupSize];

  [computeEncoder endEncoding];

  mpsStream->commit(true);
  
  result_ptr = _result_ptr.contents;

}
})
}


namespace at {
namespace native {

Tensor permute_mps(const Tensor& self, IntArrayRef dims) {
  auto nDims = self.dim();
  TORCH_CHECK(dims.size() == (size_t)nDims,
           "number of dims don't match in permute");
  auto oldSizes = self.sizes();
  auto oldStrides = self.strides();
  DimVector newSizes(nDims);
  DimVector newStrides(nDims);
  std::vector<bool> seen(nDims);
  for (const auto i : c10::irange(nDims)) {
    auto dim = maybe_wrap_dim(dims[i], nDims);
    TORCH_CHECK(!seen[dim],
             "repeated dim in permute");
    seen[dim] = true;
    newSizes[i] = oldSizes[dim];
    newStrides[i] = oldStrides[dim];
  }
  return self.as_strided(newSizes, newStrides);
}

void set_apparent_shapes(NSArray<NSNumber*> * input_shape,
                         NSArray<NSNumber*> * &apparent_input_shape,
                         int64_t num_input_dims,
                         IntArrayRef repeats,
                         NSMutableArray<NSNumber*> * &repeats_shape,
                         int64_t num_repeat_dims) {


  bool repeat_empty = false;
  if(num_repeat_dims == 0) {
    num_repeat_dims = num_input_dims;
    repeat_empty = true;
  }

  // Set repeats_shape
  repeats_shape = [NSMutableArray<NSNumber*> arrayWithCapacity:num_repeat_dims];

  for(int i = 0; i < num_repeat_dims; i++) {
    if(repeat_empty)
      repeats_shape[i] = [NSNumber numberWithInteger:1];
    else
      repeats_shape[i] = [NSNumber numberWithInteger:repeats[i]];
  }

  // If no extension of the shape is needed
  if(num_repeat_dims == num_input_dims) {
    apparent_input_shape = input_shape;
  }
  // num_repeat_dims > num_input_dims
  else {
    auto rc = [NSMutableArray<NSNumber*> arrayWithCapacity:num_repeat_dims];

    for(int i = 0; i < num_repeat_dims - num_input_dims; i++)
      rc[i] = @1;

    for(int i = num_repeat_dims - num_input_dims; i < num_repeat_dims; i++)
      rc[i] = input_shape[i + num_input_dims - num_repeat_dims];
    apparent_input_shape = rc;
  }

}





Tensor repeat_mps(const Tensor& self, IntArrayRef repeats) {

  using namespace mps;

  TORCH_CHECK(repeats.size() >= (size_t)self.dim(),
           "Number of dimensions of repeat dims can not be smaller than number of dimensions of tensor");
  struct CachedGraph : public MPSCachedGraph
  {
    CachedGraph(MPSGraph *graph) : MPSCachedGraph(graph) {}
    MPSGraphTensor *inputTensor_ = nil;
    MPSGraphTensor *outputTensor_ = nil;
  };

  MPSGraphCache* cache_ = MPSGraphCache::getInstance();

  NSArray<NSNumber*> *apparent_input_shape = nil;
  NSMutableArray<NSNumber*> *repeats_shape = nil;

  auto input_shape = getMPSShape(self);
  auto num_input_dims = [input_shape count];
  auto num_repeat_dims = repeats.size();

  set_apparent_shapes(input_shape,
                      apparent_input_shape,
                      num_input_dims,
                      repeats,
                      repeats_shape,
                      num_repeat_dims);

  // Set output shape
  std::vector<int64_t> output_shape(num_repeat_dims);
  bool zero_tensor = false;
  for(auto i : c10::irange(num_repeat_dims)) {
    output_shape[i] = repeats[i] * [apparent_input_shape[i] intValue];
    if(output_shape[i] == 0) {
      zero_tensor = true;
    }
  }

  Tensor output = at::native::empty_mps(
                      IntArrayRef(output_shape),
                      self.scalar_type(),
                      c10::nullopt,
                      kMPS,
                      c10::nullopt,
                      c10::nullopt);

  // Empty output
  if(zero_tensor || output.numel() == 0)
    return output;

  auto stream = at::mps::getCurrentMPSStream();

  @autoreleasepool {

    NSString* ns_shape_key = [[input_shape valueForKey:@"description"] componentsJoinedByString:@","];
    NSString* ns_repeats_key = [[repeats_shape valueForKey:@"description"] componentsJoinedByString:@","];

    string key = "repeat_mps:" + getMPSTypeString(self.scalar_type())
                               + ":" + string([ns_shape_key UTF8String])
                               + ":" + string([ns_repeats_key UTF8String]);
    CachedGraph* cachedGraph = static_cast<CachedGraph *>(cache_->LookUp(key));

    if(!cachedGraph) {
      MPSCachedGraph *tmpCachedGraph = cache_->CreateCachedGraph(key, ^ MPSCachedGraph * () {
        CachedGraph *newCachedGraph = nil;

        @autoreleasepool {
          MPSGraph* mpsGraph = make_mps_graph();
          newCachedGraph = new CachedGraph(mpsGraph);

          MPSGraphTensor* inputTensor = mpsGraphRankedPlaceHolder(mpsGraph, getMPSDataType(self.scalar_type()), apparent_input_shape);
          MPSGraphTensor* outputTensor = [mpsGraph tileTensor:inputTensor
                                               withMultiplier:repeats_shape
                                                         name:nil];

          newCachedGraph->inputTensor_ = inputTensor;
          newCachedGraph->outputTensor_ = outputTensor;
        }
        return newCachedGraph;
      });
      cachedGraph = static_cast<CachedGraph *>(tmpCachedGraph);
    }

    Placeholder selfPlaceholder = Placeholder(cachedGraph->inputTensor_, self, apparent_input_shape);
    Placeholder outputPlaceholder = Placeholder(cachedGraph->outputTensor_, output);

    NSDictionary<MPSGraphTensor*, MPSGraphTensorData*>* feeds = @{
      selfPlaceholder.getMPSGraphTensor() : selfPlaceholder.getMPSGraphTensorData()
    };
    NSDictionary<MPSGraphTensor*, MPSGraphTensorData*>* results = @{
      outputPlaceholder.getMPSGraphTensor() : outputPlaceholder.getMPSGraphTensorData()
    };

    runMPSGraph(stream, cachedGraph->graph(), feeds, results);
  }

  return output;

}



Tensor repeat_interleave_mps(const Tensor& repeats,c10::optional<int64_t> output_size) {
  Tensor output;
  AT_DISPATCH_INDEX_TYPES(
      repeats.scalar_type(), "repeat_interleave_mps", [&]() {
        output = repeat_interleave_common<index_t, compute_mps<index_t>>(
            repeat, output_size);
      });
  return output;
}

}
}
