require 'groundtruth_opticalflow'
require 'opticalflow_model'
require 'gnuplot'

function flow2pol(geometry, y, x)
   --y, x = onebased2centered(geometry, y, x)
   local ang = math.atan2(y, x)
   local norm = math.sqrt(x*x+y*y)
   return ang, norm
end

function flow2hsv(geometry, flow)
   local todisplay = torch.Tensor(3, flow:size(2), flow:size(3))
   for i = 1,flow:size(2) do
      for j = 1,flow:size(3) do
	 local ang, norm = flow2pol(geometry, flow[1][i][j], flow[2][i][j])
	 todisplay[1][i][j] = ang/(math.pi*2.0)
	 todisplay[2][i][j] = 1.0
	 todisplay[3][i][j] = norm/math.max(geometry.maxh/2, geometry.maxw/2)
      end
   end
   return image.hsl2rgb(todisplay)
end

function evalOpticalflow(geometry, output, gt, computeDst)
   if computeDst == nil then
      computeDst = true
   end
   local diff = (output - gt):abs()
   diff = diff[1]+diff[2]
   local hborder = math.ceil((math.max(geometry.hKernelGT, geometry.hKernel)+geometry.maxh)/2)
   local wborder = math.ceil((math.max(geometry.wKernelGT, geometry.wKernel)+geometry.maxw)/2)
   local diff = diff[{{hborder+1, -hborder-1}, {wborder+1, -wborder-1}}]
   local nGood = diff:eq(0):sum()
   local nNear = diff:eq(1):sum()
   local nBad = diff:ge(2):sum()
   
   if not computeDst then
      return nGood, nNear, nBad, 0, 0, 0
   end

   local meanDst = 0.0
   local meanDst2 = 0.0
   local d = 0.0
   local n = 0

   for i = hborder+1,output:size(2)-hborder do
      for j = wborder+1,output:size(3)-wborder do
	 local y, x = onebased2centered(geometry, output[1][i][j], output[2][i][j])
	 local ygt, xgt = onebased2centered(geometry, gt[1][i][j], gt[2][i][j])
	 y = y-ygt
	 x = x-xgt
	 local n2 = x*x+y*y
	 d = d + n2

	 meanDst = meanDst + math.sqrt(n2)
	 meanDst2 = meanDst2 + n2
	 n = n + 1
      end
   end

   d = math.sqrt(d/n)
   meanDst = meanDst / n
   meanDst2 = meanDst2 / n
   local stdDst = math.sqrt(meanDst2 - meanDst*meanDst)

   return nGood, nNear, nBad, d, meanDst, stdDst
end

function evalOpticalFlowPatches(geometry, model, raw_data, nSamples)
   nSamples = nSamples or 1000
   local testData = generateDataOpticalFlow(geometry, raw_data, nSamples, 'uniform_position')

   local criterion = nn.ClassNLLCriterion()

   local nGood = 0
   local nBad = 0
   local meanErr = 0.
   
   for t = 1,testData:size() do
      local input, target
      if geometry.multiscale then
	 local sample = testData:getElemFovea(t)
	 input = sample[1][1]
	 model:focus(sample[1][2][2], sample[1][2][1])
	 target = prepareTarget(geometry, sample[2])
      else
	 local sample = testData[t]
	 input = prepareInput(geometry, sample[1][1], sample[1][2])
	 target = prepareTarget(geometry, sample[2])
      end

      local output = model:forward(input)
      local err = criterion:forward(output:squeeze(), target)
      
      local outputp = processOutput(geometry, output, false)
      if outputp.index == target then
	 nGood = nGood + 1
      else
	 nBad = nBad + 1
      end
      meanErr = meanErr + err
   end
   collectgarbage()

   local accuracy = 1. * nGood/(nGood+nBad)
   meanErr = meanErr / (testData:size())
   
   return accuracy, meanErr
end

function evalOpticalFlowFull(geometry, model, raw_data)
   local accuracy = 0.
   local meanDst = 0.
   for i = 1,#raw_data.flow do
      local input = prepareInput(geometry, raw_data.images[i], raw_data.images[i+1])
      local output = processOutput(geometry, model:forward(input), true).full
      local gt = raw_data.flow[i]
      local nGood, nNear, nBad, d, meanDst_, stdDst = evalOpticalflow(geometry, output,
								      gt, false)
      accuracy = accuracy + 1. * nGood/(nGood+nNear+nBad)
      meanDst = meanDst + meanDst_
   end
   accuracy = accuracy / #raw_data.flow
   meanDst = meanDst / #raw_data.flow
   return accuracy, meanDst
end

function getLearningScores(dir, raw_data, mode, nSamples)
   mode = mode or 'patches'
   nSamples = nSamples or 1000
   if dir:sub(-1) ~= '/' then dir = dir .. '/' end
   local ls = ls2(dir)
   local files = {}
   for i = 1,#ls do
      if ls[i]:sub(1,11) == 'model_of__e' then
	 local iEpoch = tonumber(ls[i]:sub(12))
	 if iEpoch ~= nil then
	    table.insert(files, {iEpoch, dir .. ls[i]})
	 end
      end
   end
   table.sort(files, function(a,b) return a[1]<b[1] end)
   local ret = {}
   for i = 1,#files do
      print(i)
      local loaded = loadModel(files[i][2], mode == 'full', false)
      local acc, err
      if mode == 'patches' then
	 acc, err = evalOpticalFlowPatches(loaded.geometry, loaded.model,
					   raw_data, nSamples)
      else
	 acc, err = evalOpticalFlowFull(loaded.geometry, loaded.model, raw_data)
      end
      table.insert(ret, {files[i][1], acc, err})
   end
   return ret
end

function getLearningCurve(scores)
   local x = torch.Tensor(#scores)
   local acc = torch.Tensor(#scores)
   local err = torch.Tensor(#scores)
   for i = 1,#scores do
      x[i] = scores[i][1]
      acc[i] = scores[i][2]
      err[i] = scores[i][3]
      i = i+1
   end
   gnuplot.plot('curve', x, acc, '+-')
end