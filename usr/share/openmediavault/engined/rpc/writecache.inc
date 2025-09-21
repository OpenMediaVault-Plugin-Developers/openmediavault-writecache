<?php
/**
 * Copyright (C) 2025 openmediavault plugin developers
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

class OMVRpcServiceWriteCache extends \OMV\Rpc\ServiceAbstract
{
    public function getName()
    {
        return "WriteCache";
    }

    public function initialize()
    {
        $this->registerMethod("getSettings");
        $this->registerMethod("setSettings");
        $this->registerMethod("doFlush");
        $this->registerMethod("doTest");
    }

    public function getSettings($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.writecache");
        return $object->getAssoc();
    }

    public function setSettings($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        $db = \OMV\Config\Database::getInstance();
        $ppaths = str_replace([',',':'], PHP_EOL, $params['paths']);
        $paths = explode(PHP_EOL, $ppaths);
        $pathsT = array_map("trim", $paths);
        $pathsF = array_filter($pathsT);
        $pathsU = array_unique($pathsF);
        $params["paths"] = implode(PHP_EOL, $pathsU);
        $object = $db->get("conf.service.writecache");
        $object->setAssoc($params);
        $db->set($object);
        // Return the configuration object.
        return $object->getAssoc();
    }

    public function doFlush($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Create the background process.
        return $this->execBgProc(function($bgStatusFilename, $bgOutputFilename)
            use ($params) {
                $arg = boolval($params['rotate']) ? 'rotateflush' : 'flush';
                $cmd = new \OMV\System\Process('omv-writecache', $arg);
                $cmd->setRedirect2to1();
                $cmdLine = $cmd->getCommandLine();
                if (0 !== $this->exec($cmdLine, $output, $bgOutputFilename)) {
                    $msg = PHP_EOL . PHP_EOL . implode(PHP_EOL, $output);
                    file_put_contents($bgOutputFilename, $msg, FILE_APPEND);
                    throw new \OMV\ExecException($cmdLine, $output);
                }
                return $output;
            }
        );
    }

    public function doTest($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Create the background process.
        return $this->execBgProc(function($bgStatusFilename, $bgOutputFilename)
            use ($params) {
                $cmd = new \OMV\System\Process('omv-writecache-test');
                $cmd->setRedirect2to1();
                $cmdLine = $cmd->getCommandLine();
                if (0 !== $this->exec($cmdLine, $output, $bgOutputFilename)) {
                    $msg = PHP_EOL . PHP_EOL . implode(PHP_EOL, $output);
                    file_put_contents($bgOutputFilename, $msg, FILE_APPEND);
                    throw new \OMV\ExecException($cmdLine, $output);
                }
                return $output;
            }
        );
    }
}
