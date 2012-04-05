require 'torch'
require 'xlua'
require 'nnx'
require 'image'
require 'optim'
require 'load_data'
require 'groundtruth_opticalflow'
require 'opticalflow_model'
require 'sys'
require 'openmp'

torch.manualSeed(1)

op = xlua.OptionParser('%prog [options]')
-- general
op:option{'-nt', '--num-threads', action='store', dest='nThreads', default=2,
	  help='Number of threads used'}
-- network
op:option{'-nf', '--n-features', action='store', dest='n_features',
          default=10, help='Number of features in the first layer'}
op:option{'-k1s', '--kernel1-size', action='store', dest='kernel1_size',
	  default=5, help='Kernel 1 size, if ns == two_layers'}
op:option{'-k2s', '--kernel2-size', action='store', dest='kernel2_size',
	  default=16, help='Kernel 2 size'}
op:option{'-k3s', '--kernel3-size', action='store', dest='kernel3_size',
	  default=16, help='Kernel 3 size'}
op:option{'-ws', '--window-size', action='store', dest='win_size',
	  default=17, help='Window size (maxh)'}
op:option{'-nl', '-num-layers', action='store', dest='num_layers',
	  default=2, help='Number of layers in the network (1 or 2)'}
op:option{'-s2', '--layer-two-size', action='store', dest='layer_two_size', default=8,
	  help='Second (hidden) layer size, if ns == two_layers'}
op:option{'-s2c', '--layer-two-connections', action='store', dest='layer_two_connections',
	  default=4, help='Number of connectons between layers 1 and 2'}
op:option{'-s3', '--layer-three-size', action='store', dest='layer_three_size', default=8,
     help='Third (hidden) layer size, if ns == three_layers'}
op:option{'-s3c', '--layer-three-connections', action='store', dest='layer_three_connections',
     default=4, help='Number of connectons between layers 2 and 3'}
op:option{'-l2', '--l2-pooling', action='store_true', dest='l2_pooling', default=false,
	  help='L2 pooling'}
op:option{'-ms', '--multiscale', action='store', dest='multiscale', default=0,
	  help='Number of scales used (0 disables multiscale)'}
-- learning
op:option{'-n', '--n-train-set', action='store', dest='n_train_set', default=2000,
	  help='Number of patches in the training set'}
op:option{'-m', '--n-test-set', action='store', dest='n_test_set', default=1000,
	  help='Number of patches in the test set'}
op:option{'-e', '--num-epochs', action='store', dest='n_epochs', default=10,
	  help='Number of epochs'}
op:option{'-r', '--learning-rate', action='store', dest='learning_rate',
          default=5e-3, help='Learning rate'}
op:option{'-lrd', '--learning-rate-decay', action='store', dest='learning_rate_decay',
          default=5e-7, help='Learning rate decay'}
op:option{'-lrd2', '--learning-rate-decay2', action='store', dest='learning_rate_decay2',
          default=0, help='Learning rate decay over the epochs ( rate_i = rate/pow(iEpoch,rateDecay2) )'}
op:option{'-st', '--soft-targets', action='store_true', dest='soft_targets', default=false,
	  help='Enable soft targets (targets are gaussians centered on groundtruth)'}
op:option{'-s', '--sampling-method', action='store', dest='sampling_method',
	  default='uniform_position', help='Sampling method. uniform_position | uniform_flow'}
op:option{'-wd', '--weight-decay', action='store', dest='weight_decay',
	  default=0, help='Weight decay'}
op:option{'-rn', '--renew-train-set', action='store_true', dest='renew_train_set',
	  default=false, help='Renew train set at each epoch'}
-- input
op:option{'-rd', '--root-directory', action='store', dest='root_directory',
	  default='./data', help='Root dataset directory'}
op:option{'-fi', '--first-image', action='store', dest='first_image', default=0,
	  help='Index of first image used'}
op:option{'-d', '--delta', action='store', dest='delta', default=2,
	  help='Delta between two consecutive frames'}
op:option{'-ni', '--num-input-images', action='store', dest='num_input_images',
	  default=10, help='Number of annotated images used'}
op:option{'-mc', '--motion-correction', action='store_true', dest='motion_correction',
	  default=false, help='Eliminate panning, tilting and rotation camera movements'}

opt=op:parse()
opt.nThreads = tonumber(opt.nThreads)

opt.multiscale = tonumber(opt.multiscale)

opt.n_train_set = tonumber(opt.n_train_set)
opt.n_test_set = tonumber(opt.n_test_set)
opt.n_epochs = tonumber(opt.n_epochs)
opt.learning_rate = tonumber(opt.learning_rate)
opt.learning_rate_decay = tonumber(opt.learning_rate_decay)
opt.weight_decay = tonumber(opt.weight_decay)

opt.first_image = tonumber(opt.first_image)
opt.delta = tonumber(opt.delta)
opt.num_input_images = tonumber(opt.num_input_images)

openmp.setDefaultNumThreads(opt.nThreads)

local geometry = {}
geometry.wImg = 320
geometry.hImg = 180
geometry.maxwGT = tonumber(opt.win_size)
geometry.maxhGT = tonumber(opt.win_size)
geometry.wKernelGT = 16
geometry.hKernelGT = 16
geometry.layers = {}
if tonumber(opt.num_layers) == 1 then
   geometry.layers[1] = {3, tonumber(opt.kernel1_size), tonumber(opt.kernel1_size),
			 tonumber(opt.n_features)}
   geometry.wKernel = tonumber(opt.kernel1_size)
   geometry.hKernel = tonumber(opt.kernel1_size)
elseif tonumber(opt.num_layers) == 2 then
   geometry.layers[1] = {3, tonumber(opt.kernel1_size), tonumber(opt.kernel1_size),
			 tonumber(opt.layer_two_size)}
   geometry.layers[2] = {tonumber(opt.layer_two_connections), tonumber(opt.kernel2_size),
			 tonumber(opt.kernel2_size), tonumber(opt.n_features)}
   geometry.wKernel = tonumber(opt.kernel1_size) + tonumber(opt.kernel2_size) - 1
   geometry.hKernel = tonumber(opt.kernel1_size) + tonumber(opt.kernel2_size) - 1
elseif tonumber(opt.num_layers) == 3 then
   geometry.layers[1] = {3, tonumber(opt.kernel1_size), tonumber(opt.kernel1_size),
			 tonumber(opt.layer_two_size)}
   geometry.layers[2] = {tonumber(opt.layer_two_connections), tonumber(opt.kernel2_size),
			 tonumber(opt.kernel2_size), tonumber(opt.layer_three_size)}
   geometry.layers[3] = {tonumber(opt.layer_three_connections), tonumber(opt.kernel3_size),
			 tonumber(opt.kernel3_size), tonumber(opt.n_features)}
   geometry.wKernel = tonumber(opt.kernel1_size) + tonumber(opt.kernel2_size) + tonumber(opt.kernel3_size) - 2
   geometry.hKernel = tonumber(opt.kernel1_size) + tonumber(opt.kernel2_size) + tonumber(opt.kernel3_size) - 2
else
   assert(false)
end
geometry.soft_targets = opt.soft_targets --todo should be in learning
geometry.L2Pooling = opt.l2_pooling
if opt.multiscale == 0 then
   geometry.multiscale = false
   geometry.ratios = {1}
   geometry.maxw = geometry.maxwGT
   geometry.maxh = geometry.maxhGT
else
   geometry.multiscale = true
   geometry.ratios = {}
   for i = 1,opt.multiscale do table.insert(geometry.ratios, math.pow(2, i-1)) end
   geometry.maxw = math.ceil(geometry.maxwGT / geometry.ratios[#geometry.ratios])
   geometry.maxh = math.ceil(geometry.maxhGT / geometry.ratios[#geometry.ratios])
end
geometry.wPatch2 = geometry.maxw + geometry.wKernel - 1
geometry.hPatch2 = geometry.maxh + geometry.hKernel - 1
geometry.motion_correction = opt.motion_correction

assert(geometry.maxwGT >= geometry.maxw)
assert(geometry.maxhGT >= geometry.maxh)

local learning = {}
learning.rate = opt.learning_rate
learning.rate_decay = opt.learning_rate_decay
learning.rate_decay2 = opt.learning_rate_decay2
learning.weight_decay = opt.weight_decay
learning.sampling_method = opt.sampling_method
learning.renew_train_set = opt.renew_train_set

local summary = describeModel(geometry, learning, opt.num_input_images,
			      opt.first_image, opt.delta)

--local model
if geometry.multiscale then
   --model = getModelFovea(geometry, false)
   model = getModelMultiscale(geometry, false)
else
   model = getModel(geometry, false)
end
local parameters, gradParameters = model:getParameters()

local criterion
if geometry.soft_targets then
   criterion = nn.DistNLLCriterion()
   criterion.inputAsADistance = true
   criterion.targetIsProbability = true
else
   criterion = nn.ClassNLLCriterion()
end

print('Loading images...')
local raw_data = loadDataOpticalFlow(geometry, 'data/', opt.num_input_images,
				     opt.first_image, opt.delta, opt.motion_correction)
print('Generating training set...')
local trainData = generateDataOpticalFlow(geometry, raw_data, opt.n_train_set,
					  learning.sampling_method, opt.motion_correction)
print('Generating test set...')
local testData = generateDataOpticalFlow(geometry, raw_data, opt.n_test_set,
					 learning.sampling_method, opt.motion_correction)

saveModel('model_of_', geometry, learning, parameters, opt.num_input_images,
	  opt.first_image, opt.delta, 0)

for iEpoch = 1,opt.n_epochs do
   print('Epoch ' .. iEpoch .. ' over ' .. opt.n_epochs)
   print(summary)

   local nGood = 0
   local nBad = 0
   local meanErr = 0.

   for t = 1,testData:size() do
      modProgress(t, testData:size(), 100)

      local input, target, targetCrit
      if geometry.multiscale then
	 local sample = testData:getElemFovea(t)
	 input = sample[1][1]
	 model:focus(sample[1][2][2], sample[1][2][1])
	 targetCrit, target = prepareTarget(geometry, sample[2])
      else
	 local sample = testData[t]
	 input = prepareInput(geometry, sample[1][1], sample[1][2])
	 targetCrit, target = prepareTarget(geometry, sample[2])
      end

      local output = model:forward(input)
      --print(output:size())
      local err = criterion:forward(output:squeeze(), targetCrit)
      
      meanErr = meanErr + err
      local outputp = processOutput(geometry, output:squeeze(), false)
      --local outputp = processOutput2(geometry, output)
      --print(outputp)
      if outputp.index == target then
	 nGood = nGood + 1
      else
	 nBad = nBad + 1
      end
   end
   collectgarbage()

   meanErr = meanErr / (testData:size())
   print('test: nGood = ' .. nGood .. ' nBad = ' .. nBad .. ' (' .. 100.0*nGood/(nGood+nBad) .. '%) meanErr = ' .. meanErr)

   nGood = 0
   nBad = 0
   meanErr = 0

   if learning.renew_train_set then
      print('Generating training set...')
      trainData = generateDataOpticalFlow(geometry, raw_data, opt.n_train_set,
					  learning.sampling_method,
					  opt.motion_correction)
   end
   
   for t = 1,trainData:size() do
      modProgress(t, trainData:size(), 100)

      local input, target, targetCrit
      if geometry.multiscale then
	 local sample = trainData:getElemFovea(t)
	 input = sample[1][1]
	 model:focus(sample[1][2][2], sample[1][2][1])
	 targetCrit, target = prepareTarget(geometry, sample[2])
      else
	 local sample = trainData[t]
	 input = prepareInput(geometry, sample[1][1], sample[1][2])
	 targetCrit, target = prepareTarget(geometry, sample[2])
      end
      
      local feval = function(x)
		       if x ~= parameters then
			  parameters:copy(x)
		       end
		       gradParameters:zero()
		       local output = model:forward(input):squeeze()
		       local err = criterion:forward(output, targetCrit)
		       local df_do = criterion:backward(output, targetCrit)
		       model:backward(input, df_do)
		       
		       meanErr = meanErr + err
		       local outputp = processOutput(geometry, output, false)
		       if outputp.index == target then
			  nGood = nGood + 1
		       else
			  nBad = nBad + 1
		       end
		       return err, gradParameters
		    end

      config = {learningRate = learning.rate / math.pow(iEpoch, learning.rate_decay2),
		weightDecay = learning.weight_decay,
		momentum = 0,
		learningRateDecay = learning.rate_decay}
      optim.sgd(feval, parameters, config)
   end
   collectgarbage()
      
   meanErr = meanErr / (trainData:size())
   print('train: nGood = ' .. nGood .. ' nBad = ' .. nBad .. ' (' .. 100.0*nGood/(nGood+nBad) .. '%) meanErr = ' .. meanErr)

   saveModel('model_of_', geometry, learning, parameters, opt.num_input_images,
	     opt.first_image, opt.delta, iEpoch)

end