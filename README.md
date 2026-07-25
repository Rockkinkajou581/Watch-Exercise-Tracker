# Watch Workout Tracker

An Apple Watch app that automatically detects and logs your exercises during a workout — no manual entry required.

## How it works

The app uses a Convolutional Neural Network (CNN) that runs directly on-device, fed by the Apple Watch's IMU (gyroscope) and accelerometer data in real time. From that motion data, the model:

1. **Classifies the exercise** currently being performed (e.g. squats, push-ups, bicep curls)
2. **Counts reps** for that exercise as it's performed
3. **Logs the result** — exercise type, rep count, and timing — automatically, with no input needed from the user beyond starting and stopping

## Usage

1. Open the app and tap **Start** at the beginning of your workout
2. Move through your workout as normal — switch exercises freely, the app detects each one automatically
3. Tap **Stop** when you're done
4. Your full workout — every exercise performed and its rep count — is already logged

No manual exercise selection, no manual rep counting.
