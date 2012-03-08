require 'torch'
require 'xlua'
require 'common'

function getBinFromDepth(nBins, minDepth, binWidth, depth)
   if depth < minDepth then
      return 1
   end
   if depth-minDepth >= nBins*binWidth then
      return nBins
   else
      return math.floor((depth-minDepth)/binWidth)+1
   end
end

function isInFrame(geometry, y, x)
   return (x-geometry.wPatch/2 >= 1) and (y-geometry.hPatch/2 >= 1) and
          (x+geometry.wPatch/2 <= geometry.wImg) and (y+geometry.hPatch/2 <= geometry.hImg)
end

function preSortDataContinuous(geometry, raw_data, maxDepth, binWidth)
   local nPatches = 0
   for iImg = 1,#raw_data do
      nPatches = nPatches + raw_data[iImg][2]:size(1)
   end

   local data = {}
   data.patches = torch.Tensor(nPatches, 5) -- patch: (iImg, y, x, depth, nextOccurence)
   data.histogram = {} -- contains only usable patches
   data.perId = {}
   data.images = torch.Tensor(#raw_data, geometry.hImg, geometry.wImg)
   
   -- get patches geometry (iImg, y, x, depth) and fill data.perId and data.images
   local iPatch = 1
   for iImg = 1,#raw_data do
      xlua.progress(iImg, #raw_data)
      for iPatchInImg = 1,raw_data[iImg][2]:size(1) do
	 local y = round(raw_data[iImg][2][iPatchInImg][1]) + 1
	 local x = round(raw_data[iImg][2][iPatchInImg][2]) + 1
	 local depth = raw_data[iImg][2][iPatchInImg][3]
	 local id = raw_data[iImg][2][iPatchInImg][4]
	 if isInFrame(geometry, y, x) and depth <= maxDepth then
	    data.patches[iPatch][1] = iImg
	    data.patches[iPatch][2] = y
	    data.patches[iPatch][3] = x
	    data.patches[iPatch][4] = depth
	    data.patches[iPatch][5] = -1
	    if data.perId[id] == nil then
	       data.perId[id] = {}
	    end
	    table.insert(data.perId[id], iPatch)
	    iPatch = iPatch + 1
	 end
      end
      data.images[iImg] = image.rgb2y(raw_data[iImg][1])
   end
   nPatches = iPatch-1
   data.patches = data.patches:narrow(1, 1, nPatches)

   -- get patches next occurences (nextOccurence)
   for iId,perId in pairs(data.perId) do
      for iOcc = 1,(#perId-1) do
	 local iPatch = perId[iOcc]
	 local iPatchNext = perId[iOcc+1]
	 if data.patches[iPatchNext][1] == data.patches[iPatch][1]+1 then
	    data.patches[iPatch][5] = iPatchNext
	 end
      end
   end

   -- fill data.histogram
   --   find min and max depths
   local minDepth = 1e20
   local maxDepthData = 0
   for iPatch = 1,nPatches do
      local depth = data.patches[iPatch][4]
      if depth < minDepth then
	 minDepth = depth
      end
      if depth > maxDepthData then
	 maxDepthData = depth
      end
   end
   maxDepth = math.min(maxDepth, maxDepthData)
   --   fill histogram
   local nBins = round((maxDepth-minDepth)/binWidth)
   for i = 1,nBins do
      data.histogram[i] = {}
   end
   for iPatch = 1,nPatches do
      local iCurrentPatch = iPatch
      local goodPatch = true
      for i = 1,geometry.nImgsPerSample-1 do
	 iCurrentPatch = data.patches[iCurrentPatch][5]
	 if iCurrentPatch == -1 then
	    goodPatch = false
	    break
	 end
      end
      if goodPatch then
	 local iBin = getBinFromDepth(nBins, minDepth, binWidth, data.patches[iPatch][4])
	 table.insert(data.histogram[iBin], iPatch)
      end
   end
   --   prune small far classes
   -- todo

   print("Histogram:")
   print(data.histogram)
   -- check for empty bins
   for iBin = 1,nBins do
      if #(data.histogram[iBin]) == 0 then
	 print('Error: data.histogram[' .. iBin .. '] is empty. Use more data or larger bins.')
	 return nil
      end
   end

   return data
end

function generateContinuousDataset(geometry, data, nSamples)
   local dataset = {}
   dataset.patches = torch.Tensor(nSamples, geometry.nImgsPerSample,
				  geometry.hPatch, geometry.wPatch)
   dataset.targets = torch.Tensor(nSamples, 1):zero()
   function dataset:size()
      return nSamples
   end
   setmetatable(dataset, {__index = function(self, index)
				       return {self.patches[index], self.targets[index]}
				    end})

   for iSample = 1,nSamples do
      local iBin = randInt(1, #data.histogram+1)
      local iPatch = data.histogram[iBin][randInt(1, #data.histogram[iBin]+1)]
      dataset.targets[iSample][1] = data.patches[iPatch][4]

      local y = data.patches[iPatch][2]
      local x = data.patches[iPatch][3]

      -- for now, this is kind of stupid, but it is ready to set the target to optical flow
      for iImgIndex = 1,geometry.nImgsPerSample do
	 local iImg = data.patches[iPatch][1]
	 dataset.patches[iSample][iImgIndex] =
	    data.images[iImg]:sub(y-geometry.hPatch/2, y+geometry.hPatch/2-1,
				  x-geometry.wPatch/2, x+geometry.wPatch/2-1)
	 iPatch = data.patches[iPatch][5]
      end
   end
   
   return dataset
end

