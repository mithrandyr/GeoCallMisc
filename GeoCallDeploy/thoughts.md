Context: VM is finished

# Thoughts

* may need to install https://www.microsoft.com/en-us/download/details.aspx?id=30679 (x86 version)
* Direct link: 
https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x86.exe

https://stackoverflow.com/questions/12206314/detect-if-visual-c-redistributable-for-visual-studio-2012-is-installed
checks: HKLM\SOFTWARE\Classes\Installer\Products\1af2a8da7e60d0b429d7e6453b3d0182
HKLM:\SOFTWARE\Classes\Installer\Dependencies\{33d1fd90-4274-48a1-9bc1-97e33d9c2d6f}


* after verb, prefix rest of function name with "Config" if it touches the configuration
* Required Modules on system
    * SimplySql
* Use powershell remoting to connect to system and drive deployment
* gcdm.zip stored in azureblobcontainer

# OneTime setup for new State (how first config must be set)
* config\app\save\ticket\_savegeometry.cs
    - update 'private const string MAP = "xxx";' to your state
* 