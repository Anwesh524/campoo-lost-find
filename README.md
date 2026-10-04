# Findr: Campus Lost & Found

A mobile app that helps students recover lost items on campus. Built with
Flutter and Firebase.

Made by Anwesh for GDG USAR.

## Features
- Post lost or found items with photos, category and location
- Live shared feed per college (USAR, IIT, NIT, IIIT and others)
- Smart match alerts when a found item matches a lost one
- Urgent posts with an optional reward amount
- In-app USAR campus map with step-by-step walking directions
- One-time profile, helper rating, points, levels and badges
- Input validation and error handling on every form

## Tech stack
- Flutter (Dart)
- Firebase: Cloud Firestore and anonymous Authentication
- image_picker and shared_preferences

## Run it yourself
1. Install Flutter and Android Studio.
2. Clone this repo and run `flutter pub get`.
3. Create a Firebase project, enable **Anonymous** sign-in and **Firestore**,
   then run `flutterfire configure` to generate `lib/firebase_options.dart`.
4. Run `flutter run`, or build an APK with `flutter build apk --release`.

## Design decisions
See [DECISIONS.md](DECISIONS.md).