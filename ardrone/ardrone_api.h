#ifndef __ARDRONE_API_H_19APR12__
#define __ARDRONE_API_H_19APR12__

#include<string>

#include "drone_api.h"

const size_t controlFifoBufferLen = 33;
const size_t navdataFifoBufferLen = 98;

class ARdroneAPI : public DroneAPI {
public:
  ARdroneAPI(const std::string & control_fifo_path, const std::string & navdata_fifo_path);
  virtual ~ARdroneAPI();
public:
  virtual void next();
  virtual matf getDepthMap() const;
  virtual matf getIMUAccel() const;
  virtual matf getIMUGyro() const;
  virtual float getIMUAltitude() const;
  virtual float getBatteryState() const;
  virtual int getDroneState() const;

  virtual void takeoff();
  virtual void land();
  virtual void setControl(float pitch, float gaz, float roll, float yaw);

  virtual std::string toString() const;
private:
  int control_fifo, navdata_fifo;

  matf imuAccel, imuGyro;
  float imuAltitude, batteryState;
  int droneState;
  
  char controlFifoBuffer[controlFifoBufferLen+1];
  char navdataFifoBuffer[navdataFifoBufferLen+1];
  enum Order {
    TAKEOFF, LAND, CONTROL,
  };
  void sendOnFifo(Order order, float pitch = 0.0f, float gaz = 0.0f,
		  float roll = 0.0f, float yaw = 0.0f);
};

#endif