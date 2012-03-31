require 'torch'
require 'xlua'
require 'nnx'
require 'SmartReshape'
require 'CascadingAddTable'

function yx2x(geometry, y, x)
   return (y-1) * geometry.maxw + x
end

function x2yx(geometry, x)
   if type(x) == 'number' then
      return (math.floor((x-1)/geometry.maxw)+1), (math.mod(x-1, geometry.maxw)+1)
   else
      local xdbl = torch.DoubleTensor(x:size()):copy(x)-1
      local yout = (xdbl/geometry.maxw):floor()
      local xout = xdbl - yout*geometry.maxw
      return (yout+1.5):floor(), (xout+1.5):floor() --(a+0.5):floor() is a:round()
   end
end

function centered2onebased(geometry, y, x)
   return (y+math.ceil(geometry.maxh/2)), (x+math.ceil(geometry.maxw/2))
end

function onebased2centered(geometry, y, x)
   return (y-math.ceil(geometry.maxh/2)), (x-math.ceil(geometry.maxw/2))
end

function getModel(geometry, full_image)
   local filter = nn.Sequential()
   for i = 1,#geometry.layers do
      if i == 1 or geometry.layers[i-1][4] == geometry.layers[i][1] then
	 filter:add(nn.SpatialConvolution(geometry.layers[i][1], geometry.layers[i][4],
					  geometry.layers[i][2], geometry.layers[i][3]))
      else
	 filter:add(nn.SpatialConvolutionMap(nn.tables.random(geometry.layers[i-1][4],
							      geometry.layers[i][4],
							      geometry.layers[i][1]),
					     geometry.layers[i][2], geometry.layers[i][3]))
      end
      if i ~= #geometry.layers then
	 filter:add(nn.Tanh())
      end
   end
   assert(not geometry.L2Pooling)

   local parallel = nn.ParallelTable()
   parallel:add(filter)
   parallel:add(filter:clone('weight', 'bias', 'gradWeight', 'gradBias'))

   local model = nn.Sequential()
   model:add(parallel)
   model:add(nn.SpatialMatching(geometry.maxh, geometry.maxw, false))
   if full_image then
      model:add(nn.Reshape(geometry.maxw*geometry.maxh,
			   geometry.hImg - geometry.hPatch2 + 1,
			   geometry.wImg - geometry.wPatch2 + 1))
   else
      model:add(nn.Reshape(geometry.maxw*geometry.maxh, 1, 1))
   end

   if not geometry.soft_targets then
      model:add(nn.Minus())
      local spatial = nn.SpatialClassifier()
      spatial:add(nn.LogSoftMax())
      model:add(spatial)
   end
   
   return model
end

function getModelMultiscale(geometry, full_image)
   assert(geometry.ratios[1] == 1)
   local rmax = geometry.ratios[#geometry.ratios]
   for i = 1,#geometry.ratios do
      local k = rmax - geometry.ratios[i]
      assert(math.mod(geometry.maxh * k, 2) == 0)
      assert(math.mod(geometry.maxw * k, 2) == 0)
   end
   local nChannelsIn = geometry.layers[1][1]
   
   local filter = nn.Sequential()
   for i = 1,#geometry.layers do
      if i == 1 or geometry.layers[i-1][4] == geometry.layers[i][1] then
	 filter:add(nn.SpatialConvolution(geometry.layers[i][1], geometry.layers[i][4],
					  geometry.layers[i][2], geometry.layers[i][3]))
      else
	 filter:add(nn.SpatialConvolutionMap(nn.tables.random(geometry.layers[i-1][4],
							      geometry.layers[i][4],
							      geometry.layers[i][1]),
					     geometry.layers[i][2], geometry.layers[i][3]))
      end
      if i ~= #geometry.layers then
	 filter:add(nn.Tanh())
      end
   end
   assert(not geometry.L2Pooling)

   -- TODO check again
   local filter1 = nn.Sequential()
   filter1:add(nn.Narrow(1, 1, nChannelsIn))
   filter1:add(nn.SpatialZeroPadding(-math.ceil( geometry.maxw/2)+1,
				     -math.floor(geometry.maxw/2),
				     -math.ceil( geometry.maxh/2)+1,
  				     -math.floor(geometry.maxh/2)))
   filter1:add(filter)
   local filter2 = nn.Sequential()
   filter2:add(nn.Narrow(1, nChannelsIn+1, nChannelsIn))
   filter2:add(filter:clone('weight', 'bias', 'gradWeight', 'gradBias'))

   local matcher_filters = nn.ConcatTable()
   matcher_filters:add(filter1)
   matcher_filters:add(filter2)

   local matcher = nn.Sequential()
   matcher:add(matcher_filters)
   matcher:add(nn.SpatialMatching(geometry.maxh, geometry.maxw, false))
   if full_image then
      matcher:add(nn.SmartReshape(geometry.maxw*geometry.maxh, -3, -4))
   else
      matcher:add(nn.Reshape(geometry.maxw*geometry.maxh, 1, 1))
   end
   
   local matchers = {}
   for i = 1,#geometry.ratios do
      matchers[i] = matcher:clone()
   end

   local pyramid = nn.SpatialPyramid(geometry.ratios, matchers,
				     geometry.wPatch2, geometry.hPatch2, 1, 1)

   local model = nn.Sequential()
   model:add(nn.JoinTable(1))
   model:add(pyramid)
   local precascad = nn.ParallelTable()
   for i = 1,#geometry.ratios do
      precascad:add(nn.SmartReshape(geometry.maxh, geometry.maxw, -2, -3))
   end
   model:add(precascad)
   model:add(nn.CascadingAddTable(geometry.ratios))

   local postprocessors = nn.ParallelTable()
   postprocessors:add(nn.SmartReshape({-1,-2},-3,-4))
   for i = 2,#geometry.ratios do
      local d = math.floor(geometry.maxw*(geometry.ratios[i]-geometry.ratios[i-1])/(2*geometry.ratios[i]) + 0.5)
      local remover1 = nn.Sequential()
      local remover2 = nn.Sequential()
      local remover3 = nn.Sequential()
      local remover4 = nn.Sequential()
      remover1:add(nn.Narrow(1, 1, d))
      remover2:add(nn.Narrow(1, d+1, geometry.maxh-2*d))
      remover2:add(nn.Narrow(2, 1, d))
      remover3:add(nn.Narrow(1, d+1, geometry.maxh-2*d))
      remover3:add(nn.Narrow(2, geometry.maxw-d+1, d))
      remover4:add(nn.Narrow(1, geometry.maxh-d+1, d))
      remover1:add(nn.SmartReshape({-1,-2},-3,-4))
      remover2:add(nn.SmartReshape({-1,-2},-3,-4))
      remover3:add(nn.SmartReshape({-1,-2},-3,-4))
      remover4:add(nn.SmartReshape({-1,-2},-3,-4))
      local removers = nn.ConcatTable()
      removers:add(remover1)
      removers:add(remover2)
      removers:add(remover3)
      removers:add(remover4)
      
      local middleRemover = nn.Sequential()
      --middleRemover:add(nn.SmartReshape(geometry.maxh, geometry.maxw, -2, -3))
      middleRemover:add(removers)
      middleRemover:add(nn.JoinTable(1))
      postprocessors:add(middleRemover:clone())
   end
   
   model:add(postprocessors)
   model:add(nn.JoinTable(1))
   
   if not geometry.soft_targets then
      model:add(nn.Minus())
      local spatial = nn.SpatialClassifier()
      spatial:add(nn.LogSoftMax())
      model:add(spatial)
   end

   if not full_image then
      function model:focus(x, y)
	 pyramid:focus(x + math.ceil(geometry.wPatch2/2)-1,
		       y + math.ceil(geometry.hPatch2/2)-1,
		       1, 1)
      end
   end
   
   return model
end

function prepareInput(geometry, patch1, patch2)
   assert(patch1:size(2)==patch2:size(2) and patch1:size(3) == patch2:size(3))
   ret = {}
   --TODO this should be floor, according to the way the gt is computed. why?
   ret[1] = patch1:narrow(2, math.ceil(geometry.maxh/2), patch1:size(2)-geometry.maxh+1)
                  :narrow(3, math.ceil(geometry.maxw/2), patch1:size(3)-geometry.maxw+1)
   ret[2] = patch2
   return ret
end

function processOutput(geometry, output, process_full)
   local ret = {}
   if geometry.soft_targets then
      _, ret.index = output:min(1)
   else
      _, ret.index = output:max(1)
   end
   ret.index = ret.index:squeeze()
   ret.y, ret.x = x2yx(geometry, ret.index)
   local yoffset, xoffset = centered2onebased(geometry, 0, 0)
   ret.y = ret.y - yoffset
   ret.x = ret.x - xoffset
   if process_full == nil then
      process_full = type(ret.y) ~= 'number'
   end
   if process_full then
      local hoffset, woffset
      if output:size(2) == geometry.hImg then
	 hoffset = 0
	 woffset = 0
      else
	 hoffset = math.ceil(geometry.maxh/2) + math.ceil(geometry.hKernel/2) - 2
	 woffset = math.ceil(geometry.maxw/2) + math.ceil(geometry.wKernel/2) - 2
      end
      if type(ret.y) == 'number' then
	 ret.full = torch.Tensor(2, geometry.hPatch2, geometry.wPatch2):zero()
	 ret.full[1]:fill(math.ceil(geometry.maxh/2))
	 ret.full[2]:fill(math.ceil(geometry.maxw/2))
	 ret.full[1][1+hoffset][1+hoffset] = ret.y
	 ret.full[2][1+hoffset][1+woffset] = ret.x
      else
	 ret.full = torch.Tensor(2, geometry.hImg, geometry.wImg):zero()
	 ret.full[1]:fill(math.ceil(geometry.maxh/2))
	 ret.full[2]:fill(math.ceil(geometry.maxw/2))
	 ret.full:sub(1, 1,
		      1 + hoffset, ret.y:size(1) + hoffset,
		      1 + woffset, ret.y:size(2) + woffset):copy(ret.y)
	 ret.full:sub(2, 2,
		      1 + hoffset, ret.x:size(1) + hoffset,
		      1 + woffset, ret.x:size(2) + woffset):copy(ret.x)
      end
   end
   return ret
end

function processOutput2(geometry, output)
   local ret = {}
   if not CST_Tx then --todo : cleaner
      CST_Tx = torch.Tensor(geometry.maxh, geometry.maxw)
      CST_Ty = torch.Tensor(geometry.maxh, geometry.maxw)
      for i = 1,geometry.maxh do
	 for j = 1,geometry.maxw do
	    CST_Ty[i][j] = i-math.ceil(geometry.maxh/2)
	    CST_Tx[i][j] = j-math.ceil(geometry.maxw/2)
	 end
      end
   end
   local normer = 1.0 / (geometry.maxh*geometry.maxw)
   --local outputr = output:resize(geometry.maxh, geometry.maxw, output:size(2), output:size(3))
   local outputr = output:resize(geometry.maxh, geometry.maxw):exp()
   --print(outputr)
   image.display{image=outputr,zoom=4}
   ret.y = math.floor(outputr:dot(CST_Ty)*normer+0.5)
   ret.x = math.floor(outputr:dot(CST_Tx)*normer+0.5)
   ret.index = yx2x(geometry, ret.y, ret.x)
   return ret
end

function prepareTarget(geometry, target)
   local itarget
   if geometry.multiscale then
      function isIn(size, x)
	 return (x >= -math.ceil(size/2)+1) and (x <= math.floor(size/2))
      end
      local x = target[2]
      local y = target[1]
      local targetx, targety
      local i = 1
      while i <= #geometry.ratios do
	 if (isIn(geometry.maxw*geometry.ratios[i], x) and
	  isIn(geometry.maxh*geometry.ratios[i], y)) then
	    --todo floor? ceil? round?
	    targetx = math.floor(x/geometry.ratios[i]) + math.ceil(geometry.maxw/2)
	    targety = math.floor(y/geometry.ratios[i]) + math.ceil(geometry.maxh/2)
	    break
	 end
	 i = i + 1
      end
      assert(i <= #geometry.ratios)
      if i == 1 then
	 itarget = (targety-1) * geometry.maxw + targetx
      else
	 -- skip the middle area
	 local d = math.floor(geometry.maxw*(geometry.ratios[i]-geometry.ratios[i-1])/(2*geometry.ratios[i]) + 0.5)
	 if targety <= d then
	    itarget = (targety-1)*geometry.maxw+targetx
	 elseif targety > geometry.maxh-d then
	    itarget = d*geometry.maxw + 2*(geometry.maxh-2*d)*d
	       + (targety-(geomertry.maxh-d)-1)*geometry.maxw+targetx
	 elseif targetx <= d then
	    itarget = d*geometry.maxw + (targety-d-1)*d+targetx
	 elseif targetx > geometry.maxw-d then
	    itarget = d*geometry.maxw + (geometry.maxh-2*d)*d
	       + (targety-d-1)*d + targetx-(geometry.maxw-d)
	 else
	    assert(false)
	 end
	 itarget = geometry.maxw*geometry.maxh
	    + (i-2)*(2*d*geometry.maxw + (geometry.maxh-2*d)*d) + itarget
      end
   else
      local targetx = target[2] + math.ceil(geometry.maxw/2)
      local targety = target[1] + math.ceil(geometry.maxh/2)
      itarget = (targety-1) * geometry.maxw + targetx
   end
   --local itarget = yx2x(geometry, target[1], target[2])
   if geometry.soft_targets then
      assert(false) -- soft target not up-to-date with the centered optical flow
      local ret = torch.Tensor(geometry.maxh*geometry.maxw):zero()
      local sigma2 = 1
      local normer = 1.0 / math.sqrt(sigma2 * 2.0 * math.pi)
      for i = 1,geometry.maxh do
	 for j = 1,geometry.maxw do
	    local dist = math.sqrt((target[1]-i)*(target[1]-i)+(target[2]-j)*(target[2]-j))
	    ret[yx2x(geometry, i, j)] = normer * math.exp(-dist*dist/sigma2)
	 end
      end
      return ret, itarget
   else
      return itarget, itarget
   end
end

function describeModel(geometry, learning, nImgs, first_image, delta)
   local imgSize = 'imgSize=(' .. geometry.hImg .. 'x' .. geometry.wImg .. ')'
   local kernel = 'kernel=('
   for i = 1,#geometry.layers do
      kernel = kernel .. geometry.layers[i][1] .. 'x' .. geometry.layers[i][2] .. 'x'
      kernel = kernel .. geometry.layers[i][3] .. 'x' .. geometry.layers[i][4]
      if i ~= #geometry.layers then
	 kernel = kernel .. ', '
      end
   end
   if geometry.L2Pooling then kernel = kernel .. ' l2' end
   kernel = kernel .. ')'
   if geometry.multiscale then
      kernel = kernel .. 'x{' .. geometry.ratios[1]
      for i = 2,#geometry.ratios do
	 kernel = kernel .. ',' .. geometry.ratios[i]
      end
      kernel = kernel .. '}'
   end
   local win = 'win=(' .. geometry.maxh .. 'x' .. geometry.maxw .. ')'
   local images = 'imgs=('..first_image..':'..delta..':'.. first_image+delta*(nImgs-1)..')'
   local targets = ''
   local sampling = ''
   if geometry.soft_targets then targets = '_softTargets' end
   if learning.sampling_method ~= 'uniform_position' then
      sampling = '_' .. learning.sampling_method
   end
   local learning_ = 'learning rate=(' .. learning.rate .. ', ' .. learning.rate_decay
   learning_ = learning_ .. ') weight decay=' .. learning.weight_decay .. targets .. sampling
   local summary = imgSize .. ' ' .. kernel .. ' ' .. win .. ' ' .. images .. ' ' .. learning_
   return summary
end

function saveModel(basefilename, geometry, learning, parameters, nImgs, first_image, delta,
		   nEpochs)
   local modelsdirbase = 'models'
   local kernel = ''
   for i = 1,#geometry.layers do
      kernel = kernel .. geometry.layers[i][1] .. 'x' .. geometry.layers[i][2] .. 'x'
      kernel = kernel .. geometry.layers[i][3] .. 'x' .. geometry.layers[i][4]
      if i ~= #geometry.layers then
	 kernel = kernel .. '_'
      end
   end
   if geometry.L2Pooling then kernel = kernel .. '_l2' end
   if geometry.multiscale then
      for i = 1,#geometry.ratios do
	 kernel = kernel .. '-' .. geometry.ratios[i]
      end
   end
   local modeldir = modelsdirbase .. '/' .. kernel
   local targets = ''
   local sampling = ''
   if geometry.soft_targets then targets = ' softTargets' end
   if learning.sampling_method ~= 'uniform_position' then
      sampling = ' ' ..learning.sampling_method
   end
   local train_params = 'r' .. learning.rate .. '_rd' .. learning.rate_decay .. '_wd'
   train_params = train_params .. learning.weight_decay .. sampling .. targets
   modeldir = modeldir .. '/' .. train_params
   local images = first_image..'_'..delta..'_'..(first_image+delta*(nImgs-1))
   modeldir = modeldir .. '/' .. images
   os.execute('mkdir -p ' .. modeldir)
   torch.save(modeldir .. '/' .. basefilename .. '_e'..nEpochs,
	      {parameters, geometry})
end

function loadModel(filename, full_output)
   local loaded = torch.load(filename)
   local geometry = loaded[2]
   local model
   if geometry.multiscale then
      model = getModelMultiscale(geometry, full_output)
   else
      model = getModel(geometry, full_output)
   end
   local parameters = model:getParameters()
   parameters:copy(loaded[1])
   return geometry, model
end

function postProcessImage(input, winsize)
   local output = torch.Tensor(2, input[1]:size(1), input[1]:size(2)):zero()
   local winsizeh1 = math.ceil(winsize/2)-1
   local winsizeh2 = math.floor(winsize/2)
   local win = torch.Tensor(2,winsize,winsize)
   for i = 1+winsizeh1,output:size(2)-winsizeh2 do
      for j = 1+winsizeh1,output:size(3)-winsizeh2 do
	 win[1] = (input[1]:sub(i-winsizeh1,i+winsizeh2, j-winsizeh1, j+winsizeh2)+0.5):floor()
	 win[2] = (input[2]:sub(i-winsizeh1,i+winsizeh2, j-winsizeh1, j+winsizeh2)+0.5):floor()
	 local win2 = win:reshape(2, winsize*winsize)
	 win2 = win2:sort(2)
	 local t = 1
	 local tbest = 1
	 local nbest = 1
	 for k = 2,9 do
	    if (win2:select(2,k) - win2:select(2,t)):abs():sum(1)[1] < 0.5 then
	       if k-t > nbest then
		  nbest = k-t
		  tbest = t
	       end
	    else
	       t = k
	    end
	 end
	 output[1][i][j] = win2[1][tbest]
	 output[2][i][j] = win2[2][tbest]
      end
   end
   return output
end
